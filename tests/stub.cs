// One stub program for every external command the checker calls. tests/run.ps1 compiles it
// once and copies it to git.exe, gh.exe, claude.exe, python.exe, py.exe and winget.exe, so the
// checker finds real programs on PATH and the tests never touch the network, GitHub or the
// tools of the machine they run on.
//
// What a copy does is read from "<its own path>.rules": tab separated lines of
//     <text to find in the arguments or *>	<exit code>	<what to print>
// The first line whose text appears in the joined arguments wins. In what to print, \t and \n
// become a tab and a newline, and a leading action runs first:
//     @sleep:<seconds>   wait, so a test can make a command hang
//     @mkdir:<n>         create the directory named by argument n, counting from zero
//     @mkvenv            create <last argument>\Scripts\python.exe as a copy of this program,
//                        with venvpy.rules beside it, which is how a virtual environment looks
// Every call is appended to the file named by AIM_STUB_LOG, with the environment variables the
// checker is expected to set, so a test can assert on them.
using System;
using System.IO;
using System.Text;
using System.Threading;

public class AimStub
{
    public static int Main(string[] argv)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        string exe = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string name = Path.GetFileNameWithoutExtension(exe);
        string joined = string.Join(" ", argv);

        string log = Environment.GetEnvironmentVariable("AIM_STUB_LOG");
        if (!string.IsNullOrEmpty(log))
        {
            string seen = "GIT_TERMINAL_PROMPT=" + Env("GIT_TERMINAL_PROMPT")
                + " GIT_ASKPASS=" + Env("GIT_ASKPASS")
                + " PYTHON_MANAGER_AUTOMATIC_INSTALL=" + Env("PYTHON_MANAGER_AUTOMATIC_INSTALL");
            File.AppendAllText(log, name + "|" + joined + "|" + seen + "\n", new UTF8Encoding(false));
        }

        string rulesPath = exe + ".rules";
        if (!File.Exists(rulesPath)) { return 0; }

        foreach (string line in File.ReadAllLines(rulesPath, Encoding.UTF8))
        {
            if (line.Length == 0) { continue; }
            string[] parts = line.Split('\t');
            if (parts.Length < 2) { continue; }
            if (parts[0] != "*" && joined.IndexOf(parts[0], StringComparison.Ordinal) < 0) { continue; }
            int code = int.Parse(parts[1]);
            string text = parts.Length > 2 ? parts[2] : "";
            while (text.StartsWith("@"))
            {
                int space = text.IndexOf(' ');
                string action = space < 0 ? text : text.Substring(0, space);
                text = space < 0 ? "" : text.Substring(space + 1);
                Act(action, argv, exe);
            }
            if (text.Length > 0)
            {
                Console.Out.Write(text.Replace("\\t", "\t").Replace("\\n", "\n") + "\n");
            }
            return code;
        }
        return 0;
    }

    static string Env(string key)
    {
        string v = Environment.GetEnvironmentVariable(key);
        if (v == null) { return "unset"; }
        if (v.Length == 0) { return "empty"; }
        return v;
    }

    static void Act(string action, string[] argv, string exe)
    {
        if (action.StartsWith("@sleep:"))
        {
            Thread.Sleep(int.Parse(action.Substring(7)) * 1000);
            return;
        }
        if (action.StartsWith("@mkdir:"))
        {
            int i = int.Parse(action.Substring(7));
            if (i < argv.Length) { Directory.CreateDirectory(argv[i]); }
            return;
        }
        if (action == "@mkvenv")
        {
            string scripts = Path.Combine(argv[argv.Length - 1], "Scripts");
            Directory.CreateDirectory(scripts);
            string venvPython = Path.Combine(scripts, "python.exe");
            File.Copy(exe, venvPython, true);
            string rules = Path.Combine(Path.GetDirectoryName(exe), "venvpy.rules");
            if (File.Exists(rules)) { File.Copy(rules, venvPython + ".rules", true); }
        }
    }
}
