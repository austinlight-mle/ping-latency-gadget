using System;
using System.Diagnostics;
using System.IO;
using System.Security;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

namespace PingGadget
{
    // "Run at Windows start" is a logon scheduled task rather than a Run registry key,
    // because the app needs admin rights and Windows skips elevated apps in the Run key.
    static class Startup
    {
        const string TaskName = "PingGadget";

        public static bool IsEnabled()
        {
            return RunSchtasks("/Query /TN \"" + TaskName + "\"") == 0;
        }

        public static void SetEnabled(bool enabled)
        {
            if (!enabled)
            {
                if (IsEnabled()) RunSchtasks("/Delete /TN \"" + TaskName + "\" /F");
                return;
            }

            string user = SecurityElement.Escape(WindowsIdentity.GetCurrent().Name);
            string exe = SecurityElement.Escape(Application.ExecutablePath);
            string xml =
                "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n" +
                "<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\n" +
                "  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>" + user + "</UserId><Delay>PT5S</Delay></LogonTrigger></Triggers>\n" +
                "  <Principals><Principal id=\"Author\"><UserId>" + user + "</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>\n" +
                "  <Settings>\n" +
                "    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\n" +
                "    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\n" +
                "    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\n" +
                "    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>\n" +
                "    <Priority>7</Priority>\n" +
                "  </Settings>\n" +
                "  <Actions Context=\"Author\"><Exec><Command>" + exe + "</Command></Exec></Actions>\n" +
                "</Task>\n";

            string tmp = Path.Combine(Path.GetTempPath(), "PingGadgetTask.xml");
            File.WriteAllText(tmp, xml, Encoding.Unicode);
            try
            {
                int rc = RunSchtasks("/Create /TN \"" + TaskName + "\" /XML \"" + tmp + "\" /F");
                if (rc != 0) throw new InvalidOperationException("schtasks failed with exit code " + rc + ".");
            }
            finally
            {
                File.Delete(tmp);
            }
        }

        static int RunSchtasks(string args)
        {
            var psi = new ProcessStartInfo("schtasks.exe", args)
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (Process p = Process.Start(psi))
            {
                p.StandardOutput.ReadToEnd();
                p.StandardError.ReadToEnd();
                p.WaitForExit();
                return p.ExitCode;
            }
        }
    }
}
