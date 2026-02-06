$tmpSize = 60,30
$regPath = 'HKCU:\Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe'
$bakPath = 'HKCU:\Console\_backup'

if (Test-Path $regPath) {
    New-Item $bakPath -Force | Out-Null
    Copy-ItemProperty $regPath WindowSize -Dest $bakPath -EA SilentlyContinue
    Copy-ItemProperty $regPath ScreenBufferSize -Dest $bakPath -EA SilentlyContinue
} else {
    New-Item $bakPath -Force | Out-Null
    Set-ItemProperty $bakPath WindowSize -1
    Set-ItemProperty $bakPath ScreenBufferSize -1
}

New-Item $regPath -Force | Out-Null
Set-ItemProperty $regPath WindowSize ($tmpSize[1]*65536 + $tmpSize[0])
Set-ItemProperty $regPath ScreenBufferSize ($tmpSize[1]*65536 + $tmpSize[0])

$markName = '_SGuard_NewWin'
if ([Environment]::GetEnvironmentVariable($markName,'User') -eq '1') {
    [Environment]::SetEnvironmentVariable($markName,$null,'User')
    if ((Get-ItemProperty $bakPath WindowSize -EA 0).WindowSize -eq -1) {
        Remove-Item $regPath -Recurse -Force -EA SilentlyContinue
    } else {
        Copy-ItemProperty $bakPath WindowSize -Dest $regPath -Force
        Copy-ItemProperty $bakPath ScreenBufferSize -Dest $regPath -Force
    }
    Remove-Item $bakPath -Recurse -Force -EA SilentlyContinue
} else {
    [Environment]::SetEnvironmentVariable($markName,'1','User')
    $src = @'
'@ + $MyInvocation.MyCommand.ScriptBlock.ToString() + @'
'@
    Start-Process powershell.exe -ArgumentList '-NoExit','-Command',$src -Verb RunAs -WindowStyle Normal
    exit
}

function Show-Menu {
    param([string]$Exist)
    Clear-Host
    if ($Exist -eq "True") {
        "`n 1.覆盖重装(回车默认)"
        "`n 2.卸载"
        "`n 3.退出"
    } else {
        "`n 1.安装(回车默认)"
        "`n 2.退出"
    }
}

function New-AffinityBatFile {
    param([string]$Dir, [string[]]$Files)
    
    $processorCount = [Environment]::ProcessorCount
    $lastProcessorMask = [math]::Pow(2, $processorCount - 1)
    
    $BatContent64 = @"
wmic process where "name='SGuard64.exe'" call setpriority 64 >nul 2>&1
powershell -NoP -C "`$lastMask = [math]::Pow(2, $($processorCount-1)); Get-Process SGuard64 | %%{`$_.ProcessorAffinity = [int64]`$lastMask}"
"@
    $BatContentSvc64 = @"
wmic process where "name='SGuardSvc64.exe'" call setpriority 64 >nul 2>&1
powershell -NoP -C "`$lastMask = [math]::Pow(2, $($processorCount-1)); Get-Process SGuardSvc64 | %%{`$_.ProcessorAffinity = [int64]`$lastMask}"
"@

    New-Item -ItemType Directory -Force $script:Dir | Out-Null
    Set-Content -Path (Join-Path $script:Dir $Files[0]) -Value $BatContent64 -Encoding ASCII
    Set-Content -Path (Join-Path $script:Dir $Files[1]) -Value $BatContentSvc64 -Encoding ASCII
    Write-Host " bat文件已创建"
}

function New-AffinityTask {
    param([string]$TaskName, [string]$ProcessName, [string]$BatFile)

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $root = $service.GetFolder('\')
    $task = $service.NewTask(0)
    $task.RegistrationInfo.Description = "$ProcessName 启动即运行 ${BatFile}.bat"
    $task.Principal.UserId = 'SYSTEM'
    $task.Principal.RunLevel = 1

    $set = $task.Settings
    $set.StartWhenAvailable = $true
    $set.AllowDemandStart = $true
    $set.DisallowStartIfOnBatteries = $false
    $set.StopIfGoingOnBatteries = $false
    $set.MultipleInstances = 2

    $trigger = $task.Triggers.Create(0)
    $trigger.Subscription = @"
<QueryList>
  <Query Id='0' Path='Security'>
    <Select Path='Security'>
      *[System[EventID=4688]] and
      *[EventData[Data[@Name='NewProcessName'] and (Data="C:\Program Files\AntiCheatExpert\SGuard\x64\$ProcessName.exe")]]
    </Select>
  </Query>
</QueryList>
"@
    $trigger.Enabled = $true

    $action = $task.Actions.Create(0)
    $action.Path = (Join-Path $script:Dir $BatFile)
    $action.Arguments = ''
    $action.WorkingDirectory = 'D:\'

    $root.RegisterTaskDefinition($TaskName, $task, 6, $null, $null, 1, $null) | Out-Null
}

function Do-CommonWork {
    param([string]$Dir, [string[]]$Files, [string[]]$Tasks)

    $processorCount = [Environment]::ProcessorCount
    Write-Host " 检测到系统有 $processorCount 个逻辑处理器"
    Write-Host " 将ACE进程绑定到最后一个逻辑处理器"
    
    auditpol /set /subcategory:'{0CCE922B-69AE-11D9-BED3-505054503030}' /success:enable | Out-Null
    Write-Host " 进程创建审计已启用"
    wevtutil set-log Microsoft-Windows-TaskScheduler/Operational /enabled:true /quiet
    Write-Host " 任务历史记录已启用"

    New-AffinityBatFile -Dir $Dir -Files $Files

    New-AffinityTask -TaskName $Tasks[0] -ProcessName 'SGuard64' -BatFile $Files[0]
    New-AffinityTask -TaskName $Tasks[1] -ProcessName 'SGuardSvc64' -BatFile $Files[1]

    Write-Host " 事件任务创建成功"
    Read-Host "`n 按回车返回菜单"
    break
}

function Uninstall-Affinity {
    param([string]$Dir, [string[]]$Files, [string[]]$Tasks)

    foreach ($f in $Files) {
        Remove-Item (Join-Path $Dir $f) -Force -ErrorAction SilentlyContinue
    }
    Write-Host " BAT文件已删除"

    foreach ($t in $Tasks) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Host " 事件任务已删除"
    Read-Host "`n 按回车返回菜单"
}

while ($true) {
    Clear-Host
    $RawUI = $Host.UI.RawUI
    $RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($RawUI.WindowSize.Width, $RawUI.WindowSize.Height)

    $Dir = 'C:\Program Files\AntiCheatExpert\SGuard\x64'
    $Files = @('SGuard64_Affinity_Direct.bat', 'SGuardSvc64_Affinity_Direct.bat')
    $Tasks = @('SGuard64_Affinity_Direct', 'SGuardSvc64_Affinity_Direct')
    
    $FileExist = ($Files | ForEach-Object { Test-Path (Join-Path $Dir $_) }) -contains $true
    $TaskExist = ($Tasks | ForEach-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue }) -ne $null
    $Exist = if ($FileExist -or $TaskExist) { "True" } else { "False" }
    
    Show-Menu -Exist $Exist

    $choice = (Read-Host "`n 请输入操作").Trim().ToUpper()

    switch ($choice) {
        '1' { Do-CommonWork -Dir $Dir -Files $Files -Tasks $Tasks; break }
        '2' {
            if ($Exist -ieq "True") {
                Uninstall-Affinity -Dir $Dir -Files $Files -Tasks $Tasks
            } else {
                Get-Process -Id $PID | Stop-Process -Force
            }
            break
        }
        '3' {
            if ($Exist -ieq "True") {
                Get-Process -Id $PID | Stop-Process -Force
            }
        }
        '' { Do-CommonWork -Dir $Dir -Files $Files -Tasks $Tasks; break }
    }
}
