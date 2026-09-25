using System;
using System.Threading;
using System.Windows.Forms;

namespace PingGadget
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            bool created;
            using (var mutex = new Mutex(true, @"Local\PingGadget.SingleInstance", out created))
            {
                if (!created) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new GadgetForm(AppSettings.Load()));
            }
        }
    }
}
