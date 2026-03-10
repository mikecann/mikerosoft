using System;
using System.Threading;
using System.Windows.Forms;

namespace TaskMon {

static class Program {
    [STAThread]
    static int Main(string[] args) {
        using (var mutex = new Mutex(false, "Global\\TaskStats_SingleInstance")) {
            if (!mutex.WaitOne(0, false)) {
                MessageBox.Show(
                    "task-stats is already running.  Check the taskbar.",
                    "task-stats",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return 1;
            }

            string scriptDir = args.Length > 0 && !string.IsNullOrWhiteSpace(args[0])
                ? args[0]
                : AppContext.BaseDirectory;

            App.Run(scriptDir);
            GC.KeepAlive(mutex);
            return 0;
        }
    }
}

} // namespace TaskMon
