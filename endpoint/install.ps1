& {
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $version = 'p1-04-uat-20261024-g79a777c'
    $baseUrl = 'https://github.com/Idenity67/zinetic-endpoint-pub/releases/download/p1-04-uat-20261024-g79a777c'
    if ($env:ZINETIC_ENDPOINT_BASE_URL) {
        $baseUrl = $env:ZINETIC_ENDPOINT_BASE_URL
    }
    $baseUrl = $baseUrl.TrimEnd('/')
    $hashes = @{
        'zinetic-windows-amd64.exe'  = '4f06e094d3e4316591177a882e944e9f25d6834fd2a618b4cd2d0e5099f86484'
        'zineticd-windows-amd64.exe' = '5e71620c7d99663e7e940734fec055afa5e455575830fdaf6446f88f207ed5ac'
        'zinetic-windows-arm64.exe'  = '957bb008c70b1d610cdcdfa3009d7eb5b3d799b4983db507c8dcf1df91f4748e'
        'zineticd-windows-arm64.exe' = '0c82a1b02f7eaa6bc7c139f7ec66bfbbadb4383485d8e45a3a26c5cd38c9abf3'
    }
    $serviceName = 'ZineticEndpointCollector'
    $macCommand = 'curl -fsSL https://cli.zinetic.net/endpoint/install.sh | bash'
    $installerUrl = 'https://cli.zinetic.net/endpoint/install.ps1'
    if ($env:ZINETIC_ENDPOINT_WINDOWS_INSTALLER_URL) {
        $installerUrl = $env:ZINETIC_ENDPOINT_WINDOWS_INSTALLER_URL
    }

    function Stop-Installer([string]$message) {
        throw "zinetic installer: $message"
    }

    function Get-EndpointArchitecture {
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        switch ([int]$cpu.Architecture) {
            9 { return 'amd64' }
            12 { return 'arm64' }
        }
        Stop-Installer "this processor ($($cpu.Architecture)) is not supported; Zinetic Endpoint runs on x64 and Arm64 Windows"
    }

    function Get-EndpointState([string]$installDir) {
        $cli = Join-Path $installDir 'zinetic.exe'
        if (-not (Test-Path -LiteralPath $cli)) {
            return ''
        }
        try {
            $json = & $cli endpoint status --json 2>$null
            $global:LASTEXITCODE = 0
            $state = ($json | Out-String | ConvertFrom-Json).state
            if ($state -is [string]) {
                return $state
            }
        } catch {
            $global:LASTEXITCODE = 0
        }
        return ''
    }

    function Write-NextSteps([string]$installDir) {
        Write-Host ''
        switch (Get-EndpointState $installDir) {
            'ENROLLMENT_INCOMPLETE' {
                Write-Host 'Setup has not finished on this device. To continue it, run:'
                Write-Host '  zinetic endpoint setup'
            }
            { $_ -and $_ -notin @('NOT_INSTALLED', 'SETUP_REQUIRED', 'ENROLLMENT_INCOMPLETE') } {
                Write-Host 'This device is already set up and keeps its enrollment. To see how the endpoint is doing, run:'
                Write-Host '  zinetic endpoint status'
            }
            default {
                Write-Host 'Next, set up this device:'
                Write-Host '  zinetic endpoint setup'
            }
        }
    }

    function Invoke-Elevated([string]$installDir) {
        Write-Host 'Installing needs administrator rights, so Windows will ask you to allow PowerShell to make changes.'
        $prefix = ''
        foreach ($name in 'ZINETIC_ENDPOINT_BASE_URL', 'ZINETIC_ENDPOINT_REINSTALL', 'ZINETIC_ENDPOINT_WINDOWS_INSTALLER_URL') {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ($value) {
                $prefix += "`$env:$name = '" + $value.Replace("'", "''") + "'; "
            }
        }
        $source = $installerUrl.Replace("'", "''")
        $command = $prefix + "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; try { irm '$source' | iex; exit 0 } catch { Write-Host `$_.Exception.Message -ForegroundColor Red; Read-Host 'Press Enter to close this window'; exit 1 }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $shell = (Get-Process -Id $PID).Path
        try {
            $child = Start-Process -FilePath $shell -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
        } catch {
            Stop-Installer 'Windows did not grant administrator rights, so nothing was installed. Run the command again and choose Yes, or open PowerShell with "Run as administrator".'
        }
        if ($child.ExitCode -ne 0) {
            Stop-Installer "the installation in the administrator window did not finish (exit code $($child.ExitCode))"
        }
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        $installed = Get-InstalledVersion $installDir
        if ($installed) {
            Write-Host "Zinetic Endpoint $installed is installed in $installDir."
        }
        Write-NextSteps $installDir
    }

    function Get-InstalledVersion([string]$directory) {
        $exe = Join-Path $directory 'zinetic.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            return ''
        }
        try {
            $first = @(& $exe version 2>$null)[0]
        } catch {
            return ''
        }
        if ("$first" -match '^zinetic\s+(\S+)') {
            return $Matches[1]
        }
        return ''
    }

    function Test-SamePath([string]$a, [string]$b) {
        return $a.Trim().TrimEnd('\') -ieq $b.Trim().TrimEnd('\')
    }

    function Add-MachinePath([string]$directory) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
        try {
            $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $entries = @($raw -split ';' | Where-Object { $_ -ne '' })
            foreach ($entry in $entries) {
                if (Test-SamePath $entry $directory) {
                    return $false
                }
            }
            $key.SetValue('Path', ((@($entries) + $directory) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        } finally {
            $key.Close()
        }
        try {
            if (-not ('ZineticInstaller.Native' -as [type])) {
                Add-Type -Namespace ZineticInstaller -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);'
            }
            $result = [UIntPtr]::Zero
            [void][ZineticInstaller.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
        } catch {
            Write-Host 'Windows was not told about the new PATH; sign out and back in if zinetic is not found in new windows.'
        }
        return $true
    }

    $uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ZineticEndpoint'
    $uninstallScript = @'
& {
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $programFiles = $env:ProgramW6432
    if (-not $programFiles) {
        $programFiles = $env:ProgramFiles
    }
    $installDir = Join-Path $programFiles 'Zinetic'
    $uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ZineticEndpoint'

    function Exit-Uninstaller([int]$code, [string]$message) {
        if ($message) {
            Write-Host $message -ForegroundColor Red
            try {
                Read-Host 'Press Enter to close this window' | Out-Null
            } catch {
                $null = $_
            }
        }
        exit $code
    }

    if ($PSScriptRoot.TrimEnd('\') -ine $installDir) {
        Exit-Uninstaller 1 "This uninstaller removes Zinetic Endpoint from $installDir and runs only from there."
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        try {
            $child = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        } catch {
            Exit-Uninstaller 1 'Windows did not grant administrator rights, so Zinetic Endpoint was not removed.'
        }
        exit $child.ExitCode
    }
    Set-Location -LiteralPath $env:SystemRoot

    function Invoke-AsLocalSystem([string]$daemon, [string]$log) {
        $name = 'Zinetic Endpoint uninstall ' + [Guid]::NewGuid().ToString('N')
        $arguments = '/d /s /c ""' + $daemon + '" collector uninstall --purge > "' + $log + '" 2>&1"'
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argument $arguments
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        try {
            Start-ScheduledTask -TaskName $name
            $deadline = (Get-Date).AddMinutes(6)
            do {
                Start-Sleep -Milliseconds 500
                $state = (Get-ScheduledTask -TaskName $name).State
                $result = (Get-ScheduledTaskInfo -TaskName $name).LastTaskResult
            } while ((($state -eq 'Running') -or ($state -eq 'Queued') -or ($result -eq 267011) -or ($result -eq 267009)) -and ((Get-Date) -lt $deadline))
            if (($state -eq 'Running') -or ($result -eq 267011) -or ($result -eq 267009)) {
                return -1
            }
            return [long]$result
        } finally {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Write-Host 'Removing Zinetic Endpoint'
    $daemon = Join-Path $installDir 'zineticd.exe'
    if (Test-Path -LiteralPath $daemon) {
        Write-Host 'Removing the endpoint service, the device key, the state and the logs as LocalSystem'
        $log = Join-Path $installDir 'uninstall.log'
        $code = Invoke-AsLocalSystem $daemon $log
        if (Test-Path -LiteralPath $log) {
            Get-Content -LiteralPath $log | ForEach-Object { Write-Host "  $_" }
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        }
        if ($code -ne 0) {
            Write-Warning "zineticd could not remove everything (exit code $code); the program files are removed anyway. If this device was enrolled, ask your administrator to revoke it in the Zinetic console."
        }
    }
    $status = Join-Path $env:ProgramData 'Zinetic\Endpoint'
    Remove-Item -LiteralPath $status -Recurse -Force -ErrorAction SilentlyContinue
    $data = Join-Path $env:ProgramData 'Zinetic'
    if ((Test-Path -LiteralPath $data) -and -not (Get-ChildItem -LiteralPath $data -Force)) {
        Remove-Item -LiteralPath $data -Force -ErrorAction SilentlyContinue
    }

    foreach ($name in @('zinetic.exe', 'zineticd.exe')) {
        $file = Join-Path $installDir $name
        for ($attempt = 1; (Test-Path -LiteralPath $file) -and ($attempt -le 10); $attempt++) {
            try {
                Remove-Item -LiteralPath $file -Force
            } catch {
                if ($attempt -eq 10) {
                    Exit-Uninstaller 1 "could not remove $($file): $($_.Exception.Message)"
                }
                Start-Sleep -Seconds 1
            }
        }
    }

    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($raw -split ';' | Where-Object { $_ -ne '' })
        $kept = @($entries | Where-Object { $_.Trim().TrimEnd('\') -ine $installDir })
        if ($kept.Count -ne $entries.Count) {
            $key.SetValue('Path', ($kept -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Write-Host "Removed $installDir from the system PATH."
        }
    } finally {
        $key.Close()
    }
    try {
        if (-not ('ZineticUninstaller.Native' -as [type])) {
            Add-Type -Namespace ZineticUninstaller -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);'
        }
        $result = [UIntPtr]::Zero
        [void][ZineticUninstaller.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    } catch {
        $null = $_
    }

    Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $installDir -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'Zinetic Endpoint was removed from this device.'
    exit 0
}
'@

    function Register-Uninstaller([string]$installDir) {
        $script = Join-Path $installDir 'uninstall.ps1'
        [IO.File]::WriteAllText($script, $uninstallScript, (New-Object Text.UTF8Encoding($true)))
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $command = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$script`""
        $size = 0
        foreach ($name in @('zinetic.exe', 'zineticd.exe')) {
            $file = Join-Path $installDir $name
            if (Test-Path -LiteralPath $file) {
                $size += (Get-Item -LiteralPath $file).Length
            }
        }
        if (-not (Test-Path -LiteralPath $uninstallKey)) {
            New-Item -Path $uninstallKey -Force | Out-Null
        }
        $values = [ordered]@{
            'DisplayName'     = 'Zinetic Endpoint'
            'DisplayVersion'  = $version
            'Publisher'       = 'Zinetic'
            'InstallLocation' = $installDir
            'DisplayIcon'     = (Join-Path $installDir 'zinetic.exe')
            'UninstallString' = $command
            'URLInfoAbout'    = 'https://zinetic.net'
            'Comments'        = "Run 'zinetic endpoint uninstall' first to revoke this endpoint on the Zinetic platform."
        }
        foreach ($name in $values.Keys) {
            New-ItemProperty -Path $uninstallKey -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null
        }
        foreach ($name in @('NoModify', 'NoRepair')) {
            New-ItemProperty -Path $uninstallKey -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
        }
        New-ItemProperty -Path $uninstallKey -Name 'EstimatedSize' -Value ([int][Math]::Ceiling($size / 1KB)) -PropertyType DWord -Force | Out-Null
    }

    function Copy-Program([string]$source, [string]$destination) {
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                Copy-Item -LiteralPath $source -Destination $destination -Force
                return
            } catch {
                if ($attempt -eq 10) {
                    Stop-Installer "could not replace $($destination): $($_.Exception.Message)"
                }
                Start-Sleep -Seconds 1
            }
        }
    }

    if ($version -like '*@*') {
        Stop-Installer 'this installer template has not been rendered for a release'
    }
    if ($env:OS -ne 'Windows_NT') {
        Stop-Installer "this installer is for Windows; on macOS or Linux run: $macCommand"
    }
    $programFiles = $env:ProgramW6432
    if (-not $programFiles) {
        $programFiles = $env:ProgramFiles
    }
    $installDir = Join-Path $programFiles 'Zinetic'
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Invoke-Elevated $installDir
        return
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Host 'TLS 1.2 could not be enabled for this PowerShell session; the download may fail.'
    }

    $arch = Get-EndpointArchitecture
    $installed = Get-InstalledVersion $installDir

    if (($installed -eq $version) -and ($env:ZINETIC_ENDPOINT_REINSTALL -ne '1') -and (Test-Path -LiteralPath (Join-Path $installDir 'zineticd.exe'))) {
        Write-Host "Zinetic Endpoint $version is already installed in $installDir."
        Write-Host 'To install it again, set $env:ZINETIC_ENDPOINT_REINSTALL = "1" and run the installer again.'
    } else {
        if ($installed -and ($installed -ne $version)) {
            Write-Host "Upgrading Zinetic Endpoint from $installed to $version ($arch)"
        } else {
            Write-Host "Installing Zinetic Endpoint $version ($arch)"
        }
        $work = Join-Path ([IO.Path]::GetTempPath()) ('zinetic-endpoint-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work | Out-Null
        try {
            foreach ($name in @('zinetic', 'zineticd')) {
                $file = "$name-windows-$arch.exe"
                $download = Join-Path $work $file
                Write-Host "Downloading $file"
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$file" -OutFile $download
                } catch {
                    Stop-Installer "could not download $baseUrl/$($file): $($_.Exception.Message); nothing was installed"
                }
                $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash.ToLowerInvariant()
                if ($actual -ne $hashes[$file]) {
                    Stop-Installer "$file does not match the published checksum (expected $($hashes[$file]), got $actual); nothing was installed"
                }
            }
            Write-Host 'Checksums verified'

            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service -and ($service.Status -ne 'Stopped')) {
                Write-Host 'Stopping the endpoint service to replace its program'
                Stop-Service -Name $serviceName -Force
                $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
            }
            if (-not (Test-Path -LiteralPath $installDir)) {
                New-Item -ItemType Directory -Path $installDir | Out-Null
            }
            foreach ($name in @('zinetic', 'zineticd')) {
                Copy-Program (Join-Path $work "$name-windows-$arch.exe") (Join-Path $installDir "$name.exe")
            }
            if ($service) {
                Write-Host 'Restarting the endpoint service with the new version'
                & (Join-Path $installDir 'zineticd.exe') collector start
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning 'the endpoint service did not restart; run: zinetic endpoint restart'
                }
            }
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }

        $installed = Get-InstalledVersion $installDir
        if ($installed -ne $version) {
            Stop-Installer "the programs were copied, but $installDir\zinetic.exe reports version '$installed' instead of $version"
        }
        Write-Host ''
        Write-Host "Zinetic Endpoint $version is installed in $installDir."
    }

    if (Add-MachinePath $installDir) {
        Write-Host "Added $installDir to the system PATH. Terminal windows that were already open need to be reopened."
    }
    Register-Uninstaller $installDir
    $onPath = $false
    foreach ($entry in @($env:Path -split ';')) {
        if ($entry -and (Test-SamePath $entry $installDir)) {
            $onPath = $true
        }
    }
    if (-not $onPath) {
        $env:Path = "$env:Path;$installDir"
    }

    Write-NextSteps $installDir
}
