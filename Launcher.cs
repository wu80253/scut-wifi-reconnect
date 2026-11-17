using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("校园网设置")]

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        bool background = args.Length == 1 && args[0] == "background";
        if (args.Length != 0 && !background) return 64;

        try
        {
            string folder = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(folder, background ? "Check.ps1" : "Settings.ps1");
            string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var start = new ProcessStartInfo
            {
                FileName = powershell,
                WorkingDirectory = folder,
                Arguments = "-NoLogo -NoProfile -ExecutionPolicy RemoteSigned " +
                    (background ? "-NonInteractive" : "-STA") + " -File \"" + script + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = !background
            };
            using (Process child = Process.Start(start))
            {
                string error = background ? "" : child.StandardError.ReadToEnd().Trim();
                child.WaitForExit();
                if (!background && child.ExitCode != 0)
                {
                    if (error.Length > 360) error = error.Substring(0, 360) + "…";
                    ShowError("设置窗口启动失败。错误代码 " + child.ExitCode + ".\n" + error);
                }
                return child.ExitCode;
            }
        }
        catch (Exception error)
        {
            if (!background) ShowError("设置窗口启动失败。\n" + error.Message);
            return 1;
        }
    }

    private static void ShowError(string text)
    {
        MessageBox.Show(text, "校园网设置", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}
