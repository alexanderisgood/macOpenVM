/* SPDX-License-Identifier: Apache-2.0 */
/* Original no-CRT, in-process TLS1.3 credential-hosting evaluation. No device,
 * network, service, persistent key, system-store write or agent-health message.
 * Run only with two fresh disposable empty-password PFX fixtures. */
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#define SECURITY_WIN32
#define SCHANNEL_USE_BLACKLISTS
#include <windows.h>
#include <winternl.h>
#include <sspi.h>
#include <schannel.h>
#include <wincrypt.h>
#include "schannel_token_contract.h"
#include "schannel_record_contract.h"

_Static_assert(sizeof(void *) == 8 && sizeof(long) == 4 && sizeof(WCHAR) == 2, "Windows ARM64 LLP64");
_Static_assert(SCH_CREDENTIALS_VERSION == 5, "Modern Schannel credential contract");
#define PFX_LIMIT 262144u
#define PATH_LIMIT 1024u
#define CERT_LIMIT 65536u
#define LAB_DEADLINE 15000u

void *memcpy(void *restrict destination, const void *restrict source, size_t count) {
    volatile unsigned char *out = destination;
    const unsigned char *in = source;
    for (size_t i = 0u; i < count; ++i) out[i] = in[i];
    return destination;
}
void *memset(void *destination, int value, size_t count) {
    volatile unsigned char *out = destination;
    for (size_t i = 0u; i < count; ++i) out[i] = (unsigned char)value;
    return destination;
}
static void clear(void *bytes, size_t count) { (void)memset(bytes, 0, count); }
static bool equal(const uint8_t *a, const uint8_t *b, size_t count) {
    for (size_t i = 0u; i < count; ++i) if (a[i] != b[i]) return false;
    return true;
}
static bool wide_equal(const WCHAR *a, const WCHAR *b) {
    size_t i = 0u;
    while (i < PATH_LIMIT && a[i] != 0 && a[i] == b[i]) ++i;
    return i < PATH_LIMIT && a[i] == 0 && b[i] == 0;
}

typedef struct {
    HCERTSTORE imported, roots;
    PCCERT_CONTEXT leaf, root;
    CredHandle credential;
    bool credential_owned;
    CtxtHandle context;
    bool context_owned;
    void *alert, *initial_token;
    ULONG attributes;
    mvo_schannel_tokens tokens;
} endpoint;
static endpoint server, client;
static uint8_t pfx[PFX_LIMIT];
static WCHAR arguments[4][PATH_LIMIT];
static ULONGLONG began;
static SECURITY_STATUS native_status;
static unsigned phase;
static bool clean = true;
static const WCHAR server_name[] = L"server.macopenvm-credential-lab.invalid";
static const WCHAR client_name[] = L"client.macopenvm-credential-lab.invalid";
static uint8_t record_encrypt[MVO_SCHANNEL_RECORD_LIMIT], record_decrypt[MVO_SCHANNEL_RECORD_LIMIT];
static uint8_t record_packed[MVO_SCHANNEL_RECORD_LIMIT];
static mvo_schannel_record encrypted, decrypted;
static unsigned verified_records;

/* Closed grammar: executable plus one literal selector plus two quoted absolute
 * drive paths. No escape grammar, relative paths, device/UNC path or password.
 * The selector is an explicit lab assertion, not proof of fixture freshness. */
static bool parse_arguments(void) {
    const WCHAR *text = GetCommandLineW();
    if (text == NULL) return false;
    size_t at = 0u;
    for (unsigned arg = 0u; arg < 4u; ++arg) {
        while (at < 4096u && (text[at] == L' ' || text[at] == L'\t')) ++at;
        if (at >= 4096u || text[at] == 0) return false;
        bool quoted = text[at] == L'"';
        if (quoted) ++at;
        size_t count = 0u;
        while (at < 4096u && text[at] != 0 && (quoted ? text[at] != L'"' : text[at] != L' ' && text[at] != L'\t')) {
            if (count + 1u >= PATH_LIMIT || text[at] < 0x20u || text[at] == L'"') return false;
            arguments[arg][count++] = text[at++];
        }
        if (count == 0u || at >= 4096u || (quoted && text[at++] != L'"')) return false;
        arguments[arg][count] = 0;
        if (text[at] != 0 && text[at] != L' ' && text[at] != L'\t') return false;
    }
    while (at < 4096u && (text[at] == L' ' || text[at] == L'\t')) ++at;
    if (at >= 4096u || text[at] != 0 || !wide_equal(arguments[1], L"--fresh-empty-password-lab")) return false;
    for (unsigned arg = 2u; arg < 4u; ++arg) {
        WCHAR *path = arguments[arg];
        bool letter = (path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z');
        if (!letter || path[1] != L':' || path[2] != L'\\' || path[3] == 0) return false;
        size_t component = 3u;
        for (size_t i = 3u;; ++i) {
            if (path[i] == L':' || path[i] == L'/' || path[i] == L'*' || path[i] == L'?') return false;
            if (path[i] == L'\\' || path[i] == 0) {
                size_t length = i - component;
                if (length == 0u || path[i - 1u] == L'.' || path[i - 1u] == L' ' ||
                    (length == 1u && path[component] == L'.') ||
                    (length == 2u && path[component] == L'.' && path[component + 1u] == L'.')) return false;
                component = i + 1u;
            }
            if (path[i] == 0) break;
        }
    }
    return !wide_equal(arguments[2], arguments[3]);
}
static bool read_pfx(const WCHAR *path, DWORD *count) {
    HANDLE file = CreateFileW(path, GENERIC_READ, 0, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) { native_status = (SECURITY_STATUS)GetLastError(); return false; }
    BY_HANDLE_FILE_INFORMATION info, after;
    LARGE_INTEGER size;
    bool valid = GetFileType(file) == FILE_TYPE_DISK && GetFileInformationByHandle(file, &info) &&
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0u &&
        GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= PFX_LIMIT;
    DWORD offset = 0u;
    while (valid && offset < (DWORD)size.QuadPart) {
        DWORD actual = 0u;
        valid = ReadFile(file, pfx + offset, (DWORD)size.QuadPart - offset, &actual, NULL) &&
            actual > 0u && actual <= (DWORD)size.QuadPart - offset;
        offset += actual;
    }
    if (valid) {
        uint8_t extra = 0u;
        DWORD actual = 0u;
        valid = ReadFile(file, &extra, 1u, &actual, NULL) && actual == 0u;
    }
    if (valid) valid = GetFileInformationByHandle(file, &after) &&
        after.dwVolumeSerialNumber == info.dwVolumeSerialNumber && after.nFileIndexHigh == info.nFileIndexHigh &&
        after.nFileIndexLow == info.nFileIndexLow && after.nFileSizeHigh == info.nFileSizeHigh &&
        after.nFileSizeLow == info.nFileSizeLow && after.ftLastWriteTime.dwHighDateTime == info.ftLastWriteTime.dwHighDateTime &&
        after.ftLastWriteTime.dwLowDateTime == info.ftLastWriteTime.dwLowDateTime;
    if (!valid) native_status = (SECURITY_STATUS)GetLastError();
    if (!CloseHandle(file)) { native_status = (SECURITY_STATUS)GetLastError(); clean = false; valid = false; }
    if (valid) *count = offset;
    return valid;
}
/* Strict fixed lab SAN; no wildcard, Unicode, CN fallback or peer name policy
 * inference. CryptoAPI decoder writes only into this bounded aligned storage. */
static bool intended_name(PCCERT_CONTEXT certificate, const WCHAR *expected) {
    if (certificate == NULL || certificate->pCertInfo == NULL) return false;
    PCERT_EXTENSION extension = CertFindExtension(szOID_SUBJECT_ALT_NAME2,
        certificate->pCertInfo->cExtension, certificate->pCertInfo->rgExtension);
    if (extension == NULL || extension->Value.cbData == 0u || extension->Value.cbData > CERT_LIMIT) return false;
    static union { CERT_ALT_NAME_INFO alignment; uint8_t bytes[CERT_LIMIT]; } decoded;
    DWORD needed = 0u;
    if (!CryptDecodeObjectEx(X509_ASN_ENCODING, X509_ALTERNATE_NAME, extension->Value.pbData,
        extension->Value.cbData, 0, NULL, NULL, &needed) || needed < sizeof(CERT_ALT_NAME_INFO) || needed > sizeof(decoded)) return false;
    DWORD actual = needed;
    if (!CryptDecodeObjectEx(X509_ASN_ENCODING, X509_ALTERNATE_NAME, extension->Value.pbData,
        extension->Value.cbData, 0, NULL, decoded.bytes, &actual) || actual > needed || actual < sizeof(CERT_ALT_NAME_INFO)) return false;
    CERT_ALT_NAME_INFO *names = (CERT_ALT_NAME_INFO *)decoded.bytes;
    uintptr_t base = (uintptr_t)decoded.bytes, end = base + actual;
    uintptr_t entries = (uintptr_t)names->rgAltEntry;
    if (names->cAltEntry != 1u || entries < base || entries > end ||
        (entries % _Alignof(CERT_ALT_NAME_ENTRY)) != 0u || sizeof(CERT_ALT_NAME_ENTRY) > end - entries) return false;
    if (names->rgAltEntry[0].dwAltNameChoice != CERT_ALT_NAME_DNS_NAME) return false;
    uintptr_t address = (uintptr_t)names->rgAltEntry[0].pwszDNSName;
    if (address < base || address > end || (address & (sizeof(WCHAR) - 1u)) != 0u) return false;
    size_t available = (end - address) / sizeof(WCHAR);
    const WCHAR *name = names->rgAltEntry[0].pwszDNSName;
    size_t i = 0u;
    while (i < available && i < 128u && expected[i] != 0 && name[i] == expected[i]) ++i;
    return i < available && i < 128u && expected[i] == 0 && name[i] == 0;
}
static bool self_issued(PCCERT_CONTEXT certificate) {
    CERT_INFO *info = certificate->pCertInfo;
    return info != NULL && info->Subject.cbData > 0u && info->Subject.cbData == info->Issuer.cbData &&
        equal(info->Subject.pbData, info->Issuer.pbData, info->Subject.cbData);
}
static bool no_persisted_reference(PCCERT_CONTEXT certificate) {
    DWORD count = 0u;
    bool absent = !CertGetCertificateContextProperty(certificate, CERT_KEY_PROV_INFO_PROP_ID, NULL, &count) &&
        GetLastError() == (DWORD)CRYPT_E_NOT_FOUND;
    return absent;
}
static bool import_identity(endpoint *side, const WCHAR *path, const WCHAR *name) {
    DWORD count = 0u;
    if (!read_pfx(path, &count)) { clear(pfx, sizeof(pfx)); return false; }
    CRYPT_DATA_BLOB blob = {count, pfx};
    side->imported = PFXImportCertStore(&blob, L"",
        PKCS12_ALWAYS_CNG_KSP | PKCS12_NO_PERSIST_KEY | PKCS12_IMPORT_SILENT);
    native_status = side->imported == NULL ? (SECURITY_STATUS)GetLastError() : SEC_E_OK;
    clear(pfx, sizeof(pfx));
    if (side->imported == NULL) return false;
    PCCERT_CONTEXT current = NULL;
    unsigned certificates = 0u, keys = 0u;
    bool valid = true;
    while ((current = CertEnumCertificatesInStore(side->imported, current)) != NULL) {
        if (++certificates > 2u || current->cbCertEncoded == 0u || current->cbCertEncoded > CERT_LIMIT ||
            !no_persisted_reference(current)) { valid = false; break; }
        CERT_KEY_CONTEXT key;
        DWORD actual = sizeof(key);
        bool has_key = CertGetCertificateContextProperty(current, CERT_KEY_CONTEXT_PROP_ID, &key, &actual) != FALSE;
        if (has_key) {
            if (++keys != 1u || actual != sizeof(key) || key.cbSize != sizeof(key) ||
                key.dwKeySpec != CERT_NCRYPT_KEY_SPEC || key.hNCryptKey == 0u || !intended_name(current, name)) { valid = false; break; }
            side->leaf = CertDuplicateCertificateContext(current);
            if (side->leaf == NULL) { valid = false; break; }
        } else {
            if (GetLastError() != (DWORD)CRYPT_E_NOT_FOUND || side->root != NULL || !self_issued(current)) { valid = false; break; }
            side->root = CertDuplicateCertificateContext(current);
            if (side->root == NULL) { valid = false; break; }
        }
    }
    if (current != NULL) { if (!CertFreeCertificateContext(current)) clean = false; }
    else if (GetLastError() != (DWORD)CRYPT_E_NOT_FOUND) valid = false;
    if (!valid || certificates != 2u || keys != 1u || side->leaf == NULL || side->root == NULL) {
        native_status = SEC_E_UNKNOWN_CREDENTIALS; return false;
    }
    side->roots = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_CREATE_NEW_FLAG, NULL);
    return side->roots != NULL && CertAddCertificateContextToStore(side->roots, side->root, CERT_STORE_ADD_NEW, NULL);
}
static bool scoped_leaf(PCCERT_CONTEXT remote, endpoint *expected, const WCHAR *name, bool server_auth) {
    if (remote == NULL || remote->cbCertEncoded != expected->leaf->cbCertEncoded ||
        !equal(remote->pbCertEncoded, expected->leaf->pbCertEncoded, remote->cbCertEncoded) || !intended_name(remote, name)) return false;
    HCERTCHAINENGINE engine = NULL;
    CERT_CHAIN_ENGINE_CONFIG configuration;
    clear(&configuration, sizeof(configuration));
    configuration.cbSize = sizeof(configuration);
    configuration.hExclusiveRoot = expected->roots;
    configuration.dwFlags = CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL | CERT_CHAIN_DISABLE_AIA;
    configuration.MaximumCachedCertificates = 8u;
    if (!CertCreateCertificateChainEngine(&configuration, &engine)) return false;
    CERT_CHAIN_PARA parameters;
    clear(&parameters, sizeof(parameters)); parameters.cbSize = sizeof(parameters);
    LPSTR usage = server_auth ? szOID_PKIX_KP_SERVER_AUTH : szOID_PKIX_KP_CLIENT_AUTH;
    parameters.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND;
    parameters.RequestedUsage.Usage.cUsageIdentifier = 1u;
    parameters.RequestedUsage.Usage.rgpszUsageIdentifier = &usage;
    PCCERT_CHAIN_CONTEXT chain = NULL;
    bool valid = CertGetCertificateChain(engine, remote, NULL, remote->hCertStore, &parameters,
        CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL | CERT_CHAIN_DISABLE_AIA | CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE,
        NULL, &chain) != FALSE;
    /* This lab's fresh private CA has no revocation service. No online/cached
     * revocation qualification is claimed; no error-suppression flags are used. */
    if (valid) {
        SSL_EXTRA_CERT_CHAIN_POLICY_PARA ssl;
        CERT_CHAIN_POLICY_PARA policy;
        CERT_CHAIN_POLICY_STATUS result;
        clear(&ssl, sizeof(ssl)); clear(&policy, sizeof(policy)); clear(&result, sizeof(result));
        ssl.cbSize = sizeof(ssl); ssl.dwAuthType = server_auth ? AUTHTYPE_SERVER : AUTHTYPE_CLIENT;
        ssl.pwszServerName = server_auth ? (WCHAR *)name : NULL;
        policy.cbSize = sizeof(policy); policy.pvExtraPolicyPara = &ssl;
        result.cbSize = sizeof(result);
        valid = chain->TrustStatus.dwErrorStatus == CERT_TRUST_NO_ERROR &&
            CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain, &policy, &result) && result.dwError == 0u;
    }
    if (chain != NULL) CertFreeCertificateChain(chain);
    CertFreeCertificateChainEngine(engine);
    return valid;
}
static bool acquire(endpoint *side, endpoint *peer, bool inbound) {
    TLS_PARAMETERS tls;
    SCH_CREDENTIALS credentials;
    clear(&tls, sizeof(tls)); clear(&credentials, sizeof(credentials));
    tls.grbitDisabledProtocols = SP_PROT_PCT1 | SP_PROT_SSL2 | SP_PROT_SSL3 |
        SP_PROT_TLS1_0 | SP_PROT_TLS1_1 | SP_PROT_TLS1_2 | SP_PROT_DTLS1_0 | SP_PROT_DTLS1_2;
    credentials.dwVersion = SCH_CREDENTIALS_VERSION;
    credentials.cCreds = 1u; credentials.paCred = &side->leaf;
    credentials.hRootStore = inbound ? peer->roots : NULL;
    credentials.dwFlags = SCH_USE_STRONG_CRYPTO | SCH_CRED_CACHE_ONLY_URL_RETRIEVAL_ON_CREATE |
        (inbound ? SCH_CRED_NO_SYSTEM_MAPPER | SCH_CRED_DISABLE_RECONNECTS :
         SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS);
    credentials.cTlsParameters = 1u; credentials.pTlsParameters = &tls;
    native_status = AcquireCredentialsHandleW(NULL, UNISP_NAME_W,
        inbound ? SECPKG_CRED_INBOUND : SECPKG_CRED_OUTBOUND, NULL, &credentials,
        NULL, NULL, &side->credential, NULL);
    side->credential_owned = native_status == SEC_E_OK;
    return side->credential_owned;
}
static bool expired(void) { return GetTickCount64() - began >= LAB_DEADLINE; }
static enum mvo_schannel_status mapped(SECURITY_STATUS status) {
    switch (status) {
        case SEC_E_INCOMPLETE_MESSAGE: return MVO_SCHANNEL_INCOMPLETE;
        case SEC_I_CONTINUE_NEEDED: return MVO_SCHANNEL_CONTINUE;
        case SEC_E_OK: return MVO_SCHANNEL_COMPLETE;
        default: return MVO_SCHANNEL_FAILURE;
    }
}
static bool deliver(endpoint *from, endpoint *to) {
    if (!from->tokens.output_owned) return true;
    if (from->tokens.failed || from->tokens.output_count == 0u) return false;
    uint64_t token = 0u;
    size_t count = from->tokens.output_count;
    if (!mvo_schannel_begin_write(&from->tokens, count, &token)) return false;
    /* The receiver owns an exact copy before provider allocation release. This
     * is memory delivery, not simulated native WriteFile or peer consumption. */
    bool copied = !expired();
    if (copied && !to->tokens.context_complete) copied = mvo_schannel_append(&to->tokens, from->tokens.output, count);
    else if (copied) {
        /* A final leg can carry post-handshake ciphertext to a peer whose
         * context is already complete. Retain delivery but do not reinterpret
         * it as input to this read-first handshake contract or plaintext. */
        copied = mvo_schannel_bounds(&to->tokens) && !to->tokens.failed && !to->tokens.cancelled &&
            count <= MVO_SCHANNEL_TOKEN_LIMIT - to->tokens.input_count;
        if (copied) {
            memcpy(to->tokens.input + to->tokens.input_count, from->tokens.output, count);
            to->tokens.input_count += count;
        }
    }
    enum mvo_schannel_write_result result = mvo_schannel_observe_write(&from->tokens,
        token, copied, true, copied ? count : 0u);
    if (!copied || result != MVO_SCHANNEL_WRITE_ADVANCED) { native_status = SEC_E_INVALID_TOKEN; return false; }
    if (!mvo_schannel_can_release_output(&from->tokens)) return false;
    native_status = FreeContextBuffer((void *)from->tokens.output);
    return native_status == SEC_E_OK && mvo_schannel_output_released(&from->tokens);
}
static bool handshake_step(endpoint *side, endpoint *peer, bool inbound) {
    uint64_t token = 0u;
    if (!mvo_schannel_begin(&side->tokens, &token)) return false;
    SecBuffer inputs[2] = {{(ULONG)side->tokens.input_count, SECBUFFER_TOKEN, side->tokens.input}, {0u, SECBUFFER_EMPTY, NULL}};
    SecBufferDesc input = {SECBUFFER_VERSION, 2u, inputs};
    SecBuffer outputs[2] = {{0u, SECBUFFER_TOKEN, NULL}, {0u, SECBUFFER_ALERT, NULL}};
    SecBufferDesc output = {SECBUFFER_VERSION, 2u, outputs};
    if (!side->context_owned) SecInvalidateHandle(&side->context);
    ULONG attributes = 0u;
    ULONG requests = inbound ? ASC_REQ_STREAM | ASC_REQ_CONFIDENTIALITY | ASC_REQ_INTEGRITY |
        ASC_REQ_MUTUAL_AUTH | ASC_REQ_ALLOCATE_MEMORY : ISC_REQ_STREAM | ISC_REQ_CONFIDENTIALITY |
        ISC_REQ_INTEGRITY | ISC_REQ_MUTUAL_AUTH | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_MANUAL_CRED_VALIDATION | ISC_REQ_USE_SUPPLIED_CREDS;
    native_status = inbound ? AcceptSecurityContext(&side->credential,
        side->context_owned ? &side->context : NULL, &input, requests, 0u,
        &side->context, &output, &attributes, NULL) : InitializeSecurityContextW(&side->credential,
        &side->context, (WCHAR *)server_name, requests, 0u, 0u, &input, 0u,
        &side->context, &output, &attributes, NULL);
    if (SecIsValidHandle(&side->context)) side->context_owned = true;
    const uint8_t *extra = NULL;
    size_t extra_count = 0u;
    bool input_shape = inputs[0].BufferType == SECBUFFER_TOKEN && inputs[0].pvBuffer == side->tokens.input &&
        inputs[0].cbBuffer <= side->tokens.submitted_count;
    if (inputs[1].BufferType == SECBUFFER_EXTRA) {
        extra_count = inputs[1].cbBuffer;
        input_shape = input_shape && extra_count > 0u && extra_count <= side->tokens.submitted_count;
        /* Microsoft specifies the unprocessed count, not a copied payload or
         * an exact pvBuffer address. Derive the tail of our submitted buffer;
         * never dereference or free the provider's EXTRA pointer. */
        if (input_shape) extra = side->tokens.input + side->tokens.submitted_count - extra_count;
    }
    side->alert = outputs[1].pvBuffer;
    bool buffer_shape = input_shape && outputs[0].BufferType == SECBUFFER_TOKEN && outputs[1].BufferType == SECBUFFER_ALERT &&
        (outputs[1].pvBuffer == NULL ? outputs[1].cbBuffer == 0u : outputs[1].cbBuffer <= MVO_SCHANNEL_TOKEN_LIMIT) &&
        (inputs[1].BufferType == SECBUFFER_EMPTY || inputs[1].BufferType == SECBUFFER_EXTRA || inputs[1].BufferType == SECBUFFER_MISSING);
    SECURITY_STATUS returned = native_status;
    bool accepted = mvo_schannel_observe(&side->tokens, token, true, mapped(returned), extra,
        extra_count, outputs[0].pvBuffer, outputs[0].cbBuffer);
    if (expired()) { mvo_schannel_cancel(&side->tokens); accepted = false; }
    if (!buffer_shape) { (void)mvo_schannel_fail(&side->tokens); accepted = false; }
    if (side->alert != NULL) {
        /* Alert output is never presented as a handshake token. A refusal still
         * releases its own allocation, separately from input EXTRA and TOKEN. */
        if (side->alert == outputs[0].pvBuffer) { side->alert = NULL; accepted = false; clean = false; }
        else if (FreeContextBuffer(side->alert) != SEC_E_OK) { clean = false; accepted = false; }
        else side->alert = NULL;
    }
    if (!accepted) { native_status = returned; return false; }
    if (returned == SEC_E_OK) side->attributes = attributes;
    if (!deliver(side, peer)) return false;
    native_status = returned;
    return true;
}
/* The client's initial outbound leg has zero input and is deliberately outside
 * the read-first portable contract. It accepts only a bounded initial token. */
static bool client_initial(void) {
    SecBuffer buffers[2] = {{0u, SECBUFFER_TOKEN, NULL}, {0u, SECBUFFER_ALERT, NULL}};
    SecBufferDesc output = {SECBUFFER_VERSION, 2u, buffers};
    CtxtHandle created;
    SecInvalidateHandle(&created);
    ULONG attributes = 0u;
    native_status = InitializeSecurityContextW(&client.credential, NULL, (WCHAR *)server_name,
        ISC_REQ_STREAM | ISC_REQ_CONFIDENTIALITY | ISC_REQ_INTEGRITY | ISC_REQ_MUTUAL_AUTH |
        ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_MANUAL_CRED_VALIDATION | ISC_REQ_USE_SUPPLIED_CREDS,
        0u, 0u, NULL, 0u, &created, &output, &attributes, NULL);
    if (SecIsValidHandle(&created)) { client.context = created; client.context_owned = true; }
    SECURITY_STATUS returned = native_status;
    bool valid = returned == SEC_I_CONTINUE_NEEDED && client.context_owned && buffers[0].BufferType == SECBUFFER_TOKEN &&
        buffers[1].BufferType == SECBUFFER_ALERT && buffers[1].pvBuffer == NULL && buffers[1].cbBuffer == 0u &&
        buffers[0].pvBuffer != NULL && buffers[0].cbBuffer > 0u && buffers[0].cbBuffer <= MVO_SCHANNEL_TOKEN_LIMIT && !expired();
    if (valid) valid = mvo_schannel_append(&server.tokens, buffers[0].pvBuffer, buffers[0].cbBuffer);
    client.initial_token = buffers[0].pvBuffer;
    client.alert = buffers[1].pvBuffer;
    if (client.alert == client.initial_token && client.alert != NULL) {
        client.alert = NULL; clean = false; valid = false;
    }
    if (client.alert != NULL) {
        if (FreeContextBuffer(client.alert) != SEC_E_OK) { clean = false; valid = false; }
        else client.alert = NULL;
    }
    if (client.initial_token != NULL) {
        if (FreeContextBuffer(client.initial_token) != SEC_E_OK) { clean = false; valid = false; }
        else client.initial_token = NULL;
    }
    native_status = returned;
    return valid;
}
static bool handshake(void) {
    if (!client_initial()) return false;
    for (unsigned turn = 0u; turn < MVO_SCHANNEL_STEP_LIMIT * 2u; ++turn) {
        if (expired()) { native_status = SEC_E_CONTEXT_EXPIRED; return false; }
        bool progress = false;
        if (!server.tokens.context_complete && !server.tokens.need_input) {
            if (!handshake_step(&server, &client, true)) return false;
            progress = true;
        }
        if (!client.tokens.context_complete && !client.tokens.need_input) {
            if (!handshake_step(&client, &server, false)) return false;
            progress = true;
        }
        if (server.tokens.context_complete && client.tokens.context_complete)
            return !server.tokens.output_owned && !client.tokens.output_owned;
        if (!progress) { native_status = SEC_E_INVALID_TOKEN; return false; }
    }
    native_status = SEC_E_INVALID_TOKEN;
    return false;
}
static bool verify(endpoint *side, endpoint *peer, bool inbound) {
    if (!side->context_owned || !side->tokens.context_complete) return false;
    SecPkgContext_ConnectionInfo connection;
    clear(&connection, sizeof(connection));
    native_status = QueryContextAttributesW(&side->context, SECPKG_ATTR_CONNECTION_INFO, &connection);
    if (native_status != SEC_E_OK) return false;
    ULONG required = inbound ? ASC_RET_STREAM | ASC_RET_CONFIDENTIALITY | ASC_RET_INTEGRITY | ASC_RET_MUTUAL_AUTH :
        ISC_RET_STREAM | ISC_RET_CONFIDENTIALITY | ISC_RET_INTEGRITY | ISC_RET_MUTUAL_AUTH;
    PCCERT_CONTEXT remote = NULL;
    native_status = QueryContextAttributesW(&side->context, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &remote);
    bool valid = native_status == SEC_E_OK && remote != NULL && connection.dwProtocol ==
        (inbound ? SP_PROT_TLS1_3_SERVER : SP_PROT_TLS1_3_CLIENT) && (side->attributes & required) == required;
    if (valid) valid = mvo_schannel_verify_context(&side->tokens, true, true, true, true) &&
        scoped_leaf(remote, peer, inbound ? client_name : server_name, !inbound) &&
        mvo_schannel_verify_peer(&side->tokens, true);
    if (remote != NULL && !CertFreeCertificateContext(remote)) { clean = false; valid = false; }
    return valid && mvo_schannel_plaintext_allowed(&side->tokens);
}
static enum mvo_schannel_record_status record_status(SECURITY_STATUS status) {
    switch (status) {
        case SEC_E_OK: return MVO_RECORD_OK;
        case SEC_E_INCOMPLETE_MESSAGE: return MVO_RECORD_INCOMPLETE;
        case SEC_I_RENEGOTIATE: return MVO_RECORD_RENEGOTIATE;
        case SEC_I_CONTEXT_EXPIRED: return MVO_RECORD_EXPIRED;
        default: return MVO_RECORD_FAILURE;
    }
}
static bool stream_sizes(endpoint *side, SecPkgContext_StreamSizes *sizes) {
    if (expired() || !mvo_schannel_plaintext_allowed(&side->tokens)) return false;
    clear(sizes, sizeof(*sizes));
    native_status = QueryContextAttributesW(&side->context, SECPKG_ATTR_STREAM_SIZES, sizes);
    return native_status == SEC_E_OK && !expired() && sizes->cBuffers == 4u &&
        sizes->cbHeader > 0u && sizes->cbTrailer > 0u && sizes->cbMaximumMessage > 0u;
}
static enum mvo_schannel_record_outcome decrypt_once(endpoint *side) {
    uint64_t token = 0u;
    if (expired()) { mvo_record_cancel(&decrypted); native_status = SEC_E_CONTEXT_EXPIRED; return MVO_RECORD_REJECTED; }
    if (!mvo_record_decrypt_begin(&decrypted, &token)) return MVO_RECORD_REJECTED;
    SecBuffer buffers[4] = {{(ULONG)decrypted.input_count, SECBUFFER_DATA, record_decrypt},
        {0u, SECBUFFER_EMPTY, NULL}, {0u, SECBUFFER_EMPTY, NULL}, {0u, SECBUFFER_EMPTY, NULL}};
    SecBufferDesc message = {SECBUFFER_VERSION, 4u, buffers};
    native_status = DecryptMessage(&side->context, &message, 0u, NULL);
    SECURITY_STATUS returned = native_status;
    bool shape = true;
    mvo_schannel_record_span data = {NULL, 0u};
    size_t extra = 0u, missing = 0u;
    unsigned data_buffers = 0u, extras = 0u, missings = 0u;
    for (unsigned i = 0u; i < 4u; ++i) {
        switch (buffers[i].BufferType) {
            case SECBUFFER_DATA:
                ++data_buffers;
                if (returned == SEC_E_OK && buffers[i].cbBuffer > 0u)
                    data = (mvo_schannel_record_span){buffers[i].pvBuffer, buffers[i].cbBuffer};
                else if (buffers[i].cbBuffer > 0u) {
                    size_t offset = 0u;
                    shape = shape && mvo_record_span(&decrypted,
                        (mvo_schannel_record_span){buffers[i].pvBuffer, buffers[i].cbBuffer}, &offset) &&
                        offset <= decrypted.input_count && buffers[i].cbBuffer <= decrypted.input_count - offset;
                }
                break;
            case SECBUFFER_EXTRA: ++extras; extra = buffers[i].cbBuffer; break;
            case SECBUFFER_MISSING: ++missings; missing = buffers[i].cbBuffer; break;
            case SECBUFFER_STREAM_HEADER:
            case SECBUFFER_STREAM_TRAILER:
            case SECBUFFER_TOKEN:
                if (buffers[i].cbBuffer > 0u) {
                    size_t offset = 0u;
                    shape = shape && mvo_record_span(&decrypted,
                        (mvo_schannel_record_span){buffers[i].pvBuffer, buffers[i].cbBuffer}, &offset) &&
                        offset <= decrypted.input_count && buffers[i].cbBuffer <= decrypted.input_count - offset;
                }
                break;
            case SECBUFFER_EMPTY: shape = shape && buffers[i].cbBuffer == 0u; break;
            default: shape = false; break;
        }
    }
    shape = shape && data_buffers <= 1u && extras <= 1u && missings <= 1u &&
        (extras == 0u || extra > 0u) && (missings == 0u || missing > 0u);
    /* On non-OK status a DATA descriptor can still name ciphertext. Never
     * report it as decrypted plaintext; validate its owned span above and keep
     * the entire native-modified accumulator for incomplete/refused control. */
    if (!shape) (void)mvo_record_fail(&decrypted);
    if (expired()) mvo_record_cancel(&decrypted);
    enum mvo_schannel_record_outcome outcome = mvo_record_decrypt_return(&decrypted, token, true,
        record_status(returned), data, extra, missing);
    if (outcome == MVO_RECORD_REHANDSHAKE) {
        /* SEC_I_RENEGOTIATE can occur without EXTRA. Preserve all modified
         * ciphertext here and stop further Encrypt/Decrypt calls. A later
         * same-context ASC/ISC path with repeated scoped verification is a
         * separate gate; this evaluator never ignores the native status. */
        mvo_schannel_cancel(&side->tokens);
    }
    native_status = returned;
    return outcome;
}
static bool record_exchange(endpoint *from, endpoint *to, bool from_client) {
    SecPkgContext_StreamSizes source_sizes, target_sizes;
    if (!stream_sizes(from, &source_sizes) || !stream_sizes(to, &target_sizes)) return false;
    if (!mvo_record_init(&encrypted, record_encrypt, sizeof(record_encrypt), source_sizes.cbHeader,
        source_sizes.cbTrailer, source_sizes.cbMaximumMessage, from_client, mvo_schannel_plaintext_allowed(&from->tokens)) ||
        !mvo_record_init(&decrypted, record_decrypt, sizeof(record_decrypt), target_sizes.cbHeader,
        target_sizes.cbTrailer, target_sizes.cbMaximumMessage, from_client, mvo_schannel_plaintext_allowed(&to->tokens))) return false;
    /* Handshake leftovers are opaque ciphertext, never a record match. Consume
     * only bounded empty-data controls before submitting the public payload. */
    if (!mvo_schannel_bounds(&to->tokens)) return false;
    if (to->tokens.input_count > 0u && !mvo_record_append(&decrypted, to->tokens.input, to->tokens.input_count)) return false;
    while (decrypted.input_count > 0u) {
        enum mvo_schannel_record_outcome outcome = decrypt_once(to);
        if (outcome == MVO_RECORD_CONTROL) continue;
        if (outcome == MVO_RECORD_NEED_INPUT) break;
        return false;
    }
    uint64_t token = 0u;
    if (expired() || !mvo_record_encrypt_begin(&encrypted, &token)) return false;
    SecBuffer buffers[4] = {{source_sizes.cbHeader, SECBUFFER_STREAM_HEADER, record_encrypt},
        {(ULONG)encrypted.fixed_count, SECBUFFER_DATA, record_encrypt + encrypted.header},
        {source_sizes.cbTrailer, SECBUFFER_STREAM_TRAILER, record_encrypt + encrypted.header + encrypted.fixed_count},
        {0u, SECBUFFER_EMPTY, NULL}};
    SecBufferDesc message = {SECBUFFER_VERSION, 4u, buffers};
    native_status = EncryptMessage(&from->context, 0u, &message, 0u);
    if (expired()) mvo_record_cancel(&encrypted);
    if (buffers[0].BufferType != SECBUFFER_STREAM_HEADER || buffers[1].BufferType != SECBUFFER_DATA ||
        buffers[2].BufferType != SECBUFFER_STREAM_TRAILER || buffers[3].BufferType != SECBUFFER_EMPTY ||
        buffers[3].cbBuffer != 0u) (void)mvo_record_fail(&encrypted);
    enum mvo_schannel_record_outcome outcome = mvo_record_encrypt_return(&encrypted, token, true,
        record_status(native_status), (mvo_schannel_record_span){buffers[0].pvBuffer, buffers[0].cbBuffer},
        (mvo_schannel_record_span){buffers[1].pvBuffer, buffers[1].cbBuffer},
        (mvo_schannel_record_span){buffers[2].pvBuffer, buffers[2].cbBuffer});
    size_t produced = 0u;
    if (outcome != MVO_RECORD_CIPHERTEXT || !mvo_record_copy_ciphertext(&encrypted,
        record_packed, sizeof(record_packed), &produced) || !mvo_record_append(&decrypted, record_packed, produced)) return false;
    while (decrypted.input_count > 0u) {
        outcome = decrypt_once(to);
        if (outcome == MVO_RECORD_CONTROL) continue;
        if (outcome != MVO_RECORD_PLAINTEXT || decrypted.extra_count != 0u || expired()) return false;
        ++verified_records;
        /* Both the initial leftover and the fixed record have now been consumed.
         * No ciphertext is silently replayed in the reverse-direction test. */
        to->tokens.input_count = 0u;
        return true;
    }
    return false;
}
static void cleanup(endpoint *side) {
    mvo_schannel_cancel(&side->tokens);
    /* Failed native release remains retained for this final cleanup attempt;
     * clean stays false even if a second release succeeds. */
    if (side->initial_token != NULL && FreeContextBuffer(side->initial_token) != SEC_E_OK) clean = false;
    if (side->alert != NULL && FreeContextBuffer(side->alert) != SEC_E_OK) clean = false;
    if (side->tokens.output_owned) {
        if (!mvo_schannel_can_release_output(&side->tokens) ||
            FreeContextBuffer((void *)side->tokens.output) != SEC_E_OK || !mvo_schannel_output_released(&side->tokens)) clean = false;
    }
    if (side->context_owned && DeleteSecurityContext(&side->context) != SEC_E_OK) clean = false;
    if (side->credential_owned && FreeCredentialsHandle(&side->credential) != SEC_E_OK) clean = false;
    if (side->leaf != NULL && !CertFreeCertificateContext(side->leaf)) clean = false;
    if (side->root != NULL && !CertFreeCertificateContext(side->root)) clean = false;
    if (side->roots != NULL && !CertCloseStore(side->roots, CERT_CLOSE_STORE_CHECK_FLAG)) clean = false;
    if (side->imported != NULL && !CertCloseStore(side->imported, CERT_CLOSE_STORE_CHECK_FLAG)) clean = false;
}
static void report(bool passed, SECURITY_STATUS status, unsigned failed_phase) {
    static const char prefix[] = "mvo.schannel-credential-lab phase=";
    char output[192];
    size_t at = 0u;
    for (size_t i = 0u; i < sizeof(prefix) - 1u; ++i) output[at++] = prefix[i];
    output[at++] = (char)('0' + failed_phase / 10u); output[at++] = (char)('0' + failed_phase % 10u);
    static const char middle[] = " last-native=0x";
    for (size_t i = 0u; i < sizeof(middle) - 1u; ++i) output[at++] = middle[i];
    static const char hex[] = "0123456789abcdef";
    for (unsigned i = 0u; i < 8u; ++i) output[at++] = hex[((uint32_t)status >> ((7u - i) * 4u)) & 15u];
    const char *ending = passed ? " result=mutual-fixed-records cleanup=1 health=0 records=2\r\n" :
        clean ? " result=refused cleanup=1 health=0 records=" : " result=refused cleanup=0 health=0 records=";
    for (size_t i = 0u; ending[i] != 0; ++i) output[at++] = ending[i];
    if (!passed) { output[at++] = (char)('0' + verified_records); output[at++] = '\r'; output[at++] = '\n'; }
    DWORD written = 0u;
    HANDLE handle = GetStdHandle(STD_OUTPUT_HANDLE);
    if (handle == NULL || handle == INVALID_HANDLE_VALUE || !WriteFile(handle, output, (DWORD)at, &written, NULL) || written != at)
        ExitProcess(90u);
}
__declspec(noreturn) void mvo_start(void) {
    mvo_schannel_init(&server.tokens); mvo_schannel_init(&client.tokens);
    began = GetTickCount64();
    native_status = SEC_E_INVALID_TOKEN;
    phase = 1u;
    bool passed = parse_arguments();
    if (passed) { phase = 2u; passed = import_identity(&server, arguments[2], server_name); }
    if (passed) { phase = 3u; passed = import_identity(&client, arguments[3], client_name); }
    if (passed) {
        passed = server.root->cbCertEncoded == client.root->cbCertEncoded &&
            equal(server.root->pbCertEncoded, client.root->pbCertEncoded, server.root->cbCertEncoded) &&
            (server.leaf->cbCertEncoded != client.leaf->cbCertEncoded ||
             !equal(server.leaf->pbCertEncoded, client.leaf->pbCertEncoded, server.leaf->cbCertEncoded));
        if (!passed) native_status = SEC_E_UNKNOWN_CREDENTIALS;
    }
    if (passed) { phase = 4u; passed = scoped_leaf(server.leaf, &server, server_name, true) && scoped_leaf(client.leaf, &client, client_name, false); }
    if (passed) { phase = 5u; passed = acquire(&server, &client, true); }
    if (passed) { phase = 6u; passed = acquire(&client, &server, false); }
    if (passed) { phase = 7u; passed = handshake(); }
    if (passed) { phase = 8u; passed = verify(&server, &client, true) && verify(&client, &server, false); }
    if (passed) { phase = 9u; passed = record_exchange(&client, &server, true); }
    if (passed) { phase = 10u; passed = record_exchange(&server, &client, false); }
    passed = passed && verified_records == 2u;
    if (passed && expired()) { passed = false; native_status = SEC_E_CONTEXT_EXPIRED; }
    SECURITY_STATUS failure = native_status;
    unsigned failed_phase = phase;
    mvo_record_cancel(&encrypted); mvo_record_cancel(&decrypted);
    if (!mvo_record_can_release(&encrypted) || !mvo_record_can_release(&decrypted)) {
        /* A matching actual synchronous SSPI return must have settled before
         * this point. Refuse teardown rather than fabricate native completion. */
        clean = false; report(false, failure, failed_phase); ExitProcess(89u);
    }
    cleanup(&client); cleanup(&server);
    clear(pfx, sizeof(pfx)); clear(arguments, sizeof(arguments));
    clear(record_encrypt, sizeof(record_encrypt)); clear(record_decrypt, sizeof(record_decrypt));
    clear(record_packed, sizeof(record_packed)); clear(&encrypted, sizeof(encrypted)); clear(&decrypted, sizeof(decrypted));
    if (passed && expired()) { passed = false; failure = SEC_E_CONTEXT_EXPIRED; }
    passed = passed && clean;
    report(passed, failure, failed_phase);
    ExitProcess(passed ? 0u : clean ? failed_phase : 89u);
}
