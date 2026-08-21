// Thin native launcher for the ROM capture tool. Deliberately does NOT
// reimplement any orchestration logic -- it just shells out to the same,
// already-proven rom_launcher.ps1 via powershell.exe, hidden, and waits for
// it to exit. This mirrors how rom_launcher.bat already worked, just
// without a visible console window or needing the .bat file at all.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

class Program
{
    [STAThread]
    static void Main()
    {
        string exeDir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        string scriptPath = Path.Combine(exeDir, "scripts", "rom_launcher.ps1");

        if (!File.Exists(scriptPath))
        {
            MessageBox.Show(
                "Could not find rom_launcher.ps1 at:\n" + scriptPath,
                "ROM Launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"",
            UseShellExecute = false,
            CreateNoWindow = true
        };

        try
        {
            using (var proc = Process.Start(psi))
            {
                proc.WaitForExit();
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Failed to launch rom_launcher.ps1:\n" + ex.Message,
                "ROM Launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
