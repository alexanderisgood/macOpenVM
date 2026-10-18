// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Two fixed, unprivileged Windows diagnostics. No arbitrary script, credential,
/// policy change, network request or screenshot output is accepted.
enum WindowsCS2PerformanceSample {
  static func command(read: Bool) -> String {
    let script = read ? reader : sampler
    let bytes = script.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
    return "powershell.exe -NoLogo -NoProfile "
      + (read ? "-NoExit " : "-WindowStyle Minimized ")
      + "-EncodedCommand " + Data(bytes).base64EncodedString()
  }

  private static let sampler = """
    $ErrorActionPreference='Stop';$p=Get-Process cs2;$r=@();
    $s=[Diagnostics.Stopwatch]::StartNew();$last=$p.TotalProcessorTime.TotalMilliseconds;
    for($i=0;$i -lt 30;$i++){
      Start-Sleep -Seconds 1;$p.Refresh();$cpu=$p.TotalProcessorTime.TotalMilliseconds;
      $r+=[pscustomobject]@{ms=[math]::Round($s.Elapsed.TotalMilliseconds);
        utc=[DateTime]::UtcNow.ToString('HH:mm:ss.fff');
        cpuMS=[math]::Round($cpu-$last);ramMB=[math]::Round($p.WorkingSet64/1MB)};
      $last=$cpu
    };
    $json=ConvertTo-Json -InputObject $r -Compress;
    Set-Content -Value $json -LiteralPath (Join-Path $env:TEMP 'macOpenVM-CS2-pacing-20261015.json')
    """
  private static let reader = """
    $ErrorActionPreference='Stop';
    $a=Get-Content -Raw -LiteralPath (Join-Path $env:TEMP 'macOpenVM-CS2-pacing-20261015.json');
    $rows=ConvertFrom-Json -InputObject $a;
    Write-Output 'elapsedMS UTC CPUms RAMmb';
    foreach($row in $rows){
      Write-Output ('{0,8} {1} {2,6} {3,6}' -f $row.ms,$row.utc,$row.cpuMS,$row.ramMB)
    }
    """
}
