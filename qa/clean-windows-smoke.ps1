# Public QA recipe only: operates the signed installer and visible user journey.
# No owner key, server credential, source code, runtime plaintext or capability is exported.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Security
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class StudioQaDesktop {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr handle,int index,StringBuilder data,uint length,out uint needed);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
}
'@
$result=[ordered]@{status='started';runId=$env:GITHUB_RUN_ID;runnerOS=(Get-CimInstance Win32_OperatingSystem).Caption;scope='Clean hosted Windows VM, actual signed public installer, ordinary app UI, native CNG/DPAPI and production trial service. No vehicle/interface write, owner key or runtime plaintext export.';vehicleOperations=0}
$qaProcess=$null
function Wait-Value([scriptblock]$Read,[int]$Seconds=90){
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $Seconds){$value=& $Read;if($null -ne $value -and $value -ne $false){return $value};Start-Sleep -Milliseconds 1000}
  throw 'qa_expected_ui_not_reached'
}
function Visible-OwnedWindow($Element){
  if(!$Element){return $false};$current=$Element.Current;$bounds=$current.BoundingRectangle
  return $current.ProcessId -eq $qaProcess.Id -and !$current.IsOffscreen -and $bounds.Width -gt 0 -and $bounds.Height -gt 0 -and [StudioQaDesktop]::IsWindowVisible([IntPtr]::new($current.NativeWindowHandle))
}
function Window([string]$Title){
  if(!$qaProcess -or $qaProcess.HasExited){return $null}
  $condition=[Windows.Automation.AndCondition]::new(
    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,[int]$qaProcess.Id),
    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$Title))
  $found=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,$condition)
  if(Visible-OwnedWindow $found){return $found};return $null
}
function Named($Root,[string]$Name){
  return $Root.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$Name))
}
function Click($Element){if(!$Element){throw 'qa_expected_button_missing'};$Element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Read-Trial(){
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\PWC LAB\Engine Studio\Protected Beta v1',$false)
  if(!$key){throw 'qa_trial_not_persisted'}
  try {
    $wrapped=$key.GetValue('License',$null);if($wrapped -isnot [byte[]]){throw 'qa_trial_not_persisted'}
    $raw=[Security.Cryptography.ProtectedData]::Unprotect($wrapped,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try {
      $envelope=[Text.Encoding]::UTF8.GetString($raw)|ConvertFrom-Json
      if($envelope.algorithm -cne 'ES256-P1363' -or $envelope.version -ne 1){throw 'qa_signed_trial_envelope_invalid'}
      $encoded=$envelope.payload.Replace('-','+').Replace('_','/');$encoded=$encoded.PadRight([int]([Math]::Ceiling($encoded.Length/4)*4),'=')
      $payload=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))|ConvertFrom-Json
      # Only this projection leaves process memory; the envelope and device identity do not.
      return @{startedAt=$payload.startedAt;expiresAt=$payload.expiresAt;revision=$payload.revision;ciphertextSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($wrapped)).ToLowerInvariant();runtimeGrants=@($key.GetValueNames()|Where-Object {$_ -like 'Runtime_*'}).Count}
    }finally{[Array]::Clear($raw,0,$raw.Length)}
  }finally{$key.Close()}
}
function Observe-Main(){
  $main=Wait-Value {Window 'PWC LAB Engine Studio'}
  # Leave startup/discovery alone before a single scoped observation. UIA polling itself
  # can distort the timing being tested; window-title discovery does not read the DOM.
  Start-Sleep -Seconds 40
  if(!(Visible-OwnedWindow $main)){throw 'qa_expected_visible_main_not_ready'}
  if(!(Named $main 'NO VEHICLE CONNECTED')){throw 'qa_expected_offline_main_not_ready'}
  $texts=$main.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Text))
  $banner=@($texts|ForEach-Object {$_.Current.Name}|Where-Object {$_ -like 'Beta trial ends * ECU flashing is unavailable in this beta.'})
  if($banner.Count -ne 1){throw 'qa_active_trial_banner_missing'}
  return @{window=$main;trialBanner=$banner[0]}
}
function Close-Main($Main){
  $Main.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
  if(!$qaProcess.WaitForExit(20000) -or $qaProcess.ExitCode -ne 0){throw 'qa_app_did_not_exit_naturally'}
}
try {
  $desktop=[StudioQaDesktop]::OpenInputDesktop(0,$false,1);$desktopName=[Text.StringBuilder]::new(256);[uint32]$needed=0
  $desktopNamed=$desktop -ne [IntPtr]::Zero -and [StudioQaDesktop]::GetUserObjectInformation($desktop,2,$desktopName,512,[ref]$needed)
  if($desktop -ne [IntPtr]::Zero){[void][StudioQaDesktop]::CloseDesktop($desktop)}
  $result.interactiveDesktop=@{userInteractive=[Environment]::UserInteractive;positiveSessionId=([Diagnostics.Process]::GetCurrentProcess().SessionId -gt 0);inputDesktopDefault=($desktopNamed -and $desktopName.ToString() -ceq 'Default')}
  if(!$result.interactiveDesktop.userInteractive -or !$result.interactiveDesktop.positiveSessionId -or !$result.interactiveDesktop.inputDesktopDefault){throw 'qa_interactive_desktop_unavailable'}
  $url=[uri]$env:STUDIO_INSTALLER_URL;$sha=$env:STUDIO_INSTALLER_SHA256
  if($url.Scheme -cne 'https' -or $url.Host -cne 'github.com' -or $url.AbsolutePath -notmatch '^/mike9812121298/pwclab-engine-studio-downloads/releases/download/beta-1\.0\.53-test\.[0-9]+/Engine-Studio-Beta-[0-9]+-Windows-x64\.exe$' -or $url.Query -or $sha -cnotmatch '^[a-f0-9]{64}$'){throw 'qa_installer_input_invalid'}
  $activate=$env:STUDIO_QA_ACTIVATE -ceq 'true';$invitation=$env:STUDIO_QA_INVITATION
  if($activate){if($invitation -cnotmatch '^ESI1-[A-Za-z0-9_-]{43}$'){throw 'qa_one_time_invitation_missing'};Write-Output ('::add-mask::'+$invitation)}
  $trialKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\PWC LAB\Engine Studio\Protected Beta v1',$false)
  if($trialKey){$trialKey.Close();throw 'qa_environment_not_clean'}
  $installed=Join-Path $env:LOCALAPPDATA 'Programs\PWC LAB Engine Studio Full Program Bench\PWC LAB Engine Studio Full Program Bench.exe'
  if(Test-Path -LiteralPath $installed){throw 'qa_environment_not_clean'}
  $result.cleanInitialRegistry=$true;$result.cleanInitialInstall=$true
  $installer=Join-Path $env:RUNNER_TEMP 'Engine-Studio-reviewed-installer.exe'
  Invoke-WebRequest -Uri $url -OutFile $installer
  if((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sha){throw 'qa_public_installer_hash_mismatch'}
  $signature=Get-AuthenticodeSignature -LiteralPath $installer
  if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -cne 'CN=GT40MARINE, O=GT40MARINE, L=BONNEY LAKE, S=Washington, C=US' -or !$signature.TimeStamperCertificate){throw 'qa_public_installer_signature_invalid'}
  $result.installerSha256=$sha;$result.signature='Valid GT40MARINE, timestamped'
  $setup=Start-Process -FilePath $installer -ArgumentList @('/S','/CURRENTUSER') -PassThru -Wait
  if($setup.ExitCode -ne 0 -or !(Test-Path -LiteralPath $installed)){throw 'qa_install_failed'}
  $result.fileVersion=(Get-Item -LiteralPath $installed).VersionInfo.FileVersion
  $tagVersion=[regex]::Match($url.AbsolutePath,'/beta-1\.0\.53-test\.([0-9]+)/').Groups[1].Value
  if($result.fileVersion -cne ('1.0.53.'+$tagVersion) -or !$url.AbsolutePath.EndsWith('/Engine-Studio-Beta-'+$tagVersion+'-Windows-x64.exe')){throw 'qa_installed_version_mismatch'}
  $qaProcess=Start-Process -FilePath $installed -PassThru
  $activation=Wait-Value {Window 'Activate Engine Studio'}
  if(!(Named $activation 'Invitation code from GT40 Marine')){throw 'qa_invitation_label_incorrect'}
  $edit=$activation.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Edit))
  if(!$edit){throw 'qa_invitation_field_missing'}
  $value=$edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
  $value.SetValue('qa@example.invalid');Click (Named $activation 'Start 72-hour trial');Start-Sleep -Seconds 1
  $text=@($activation.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {$_.Current.Name}) -join ' '
  if(!$text.Contains('Paste an invitation code starting with ESI1-. Your email address cannot be used here.') -or !(Window 'Activate Engine Studio')){throw 'qa_local_email_guidance_missing'}
  $result.emailGuidanceObserved=$true;$result.visibleActivationWindow=$true
  if(!$activate){
    $activation.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
    if(!$qaProcess.WaitForExit(20000) -or $qaProcess.ExitCode -ne 0){throw 'qa_activation_window_close_failed'}
    $result.status='preflight-passed';$result.trialActivationExecuted=$false;$result.finishedAt=[DateTime]::UtcNow.ToString('o')
    Write-Output ('CLEAN_WINDOWS_QA_PROOF='+($result|ConvertTo-Json -Depth 5 -Compress));exit 0
  }
  $value.SetValue($invitation);Click (Named $activation 'Start 72-hour trial')
  $main=Observe-Main;$first=Read-Trial
  if([long]$first.expiresAt-[long]$first.startedAt -ne 72*60*60*1000 -or $first.revision -ne 1 -or $first.runtimeGrants -lt 1){throw 'qa_first_trial_or_runtime_invalid'}
  $result.firstTrial=$first;$result.firstMainReached=$true;$result.firstTrialBanner=$main.trialBanner
  Close-Main $main.window
  # Reinstall the exact customer installer without deleting profile, CNG or licensing state.
  $setup=Start-Process -FilePath $installer -ArgumentList @('/S','/CURRENTUSER') -PassThru -Wait
  if($setup.ExitCode -ne 0){throw 'qa_reinstall_failed'}
  $qaProcess=Start-Process -FilePath $installed -PassThru;$again=Observe-Main;$second=Read-Trial
  if($first.startedAt -ne $second.startedAt -or $first.expiresAt -ne $second.expiresAt -or $first.revision -ne $second.revision -or $first.ciphertextSha256 -cne $second.ciphertextSha256){throw 'qa_reinstall_restarted_or_changed_trial'}
  $result.reinstallPreservedOriginalTrial=$true;$result.secondTrial=$second;Close-Main $again.window
  $result.status='passed';$result.trialActivationExecuted=$true;$result.finishedAt=[DateTime]::UtcNow.ToString('o')
}catch{
  # Deliberately no full UI tree, screenshot, exception arguments, private envelope or code.
  $result.status='failed';$message=$_.Exception.Message;$result.failureCode=if($message -cmatch '^qa_[a-z0-9_]+$'){$message}else{'qa_unexpected_runtime_failure'}
  $result.finishedAt=[DateTime]::UtcNow.ToString('o')
}
Write-Output ('CLEAN_WINDOWS_QA_PROOF='+($result|ConvertTo-Json -Depth 5 -Compress))
if($result.status -ne 'passed'){exit 1}
