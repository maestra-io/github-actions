using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using Microsoft.VisualStudio.TestTools.UnitTesting;

[assembly: Parallelize(Scope = ExecutionScope.MethodLevel)]

namespace SdkSelect.Tests;

// The workflow asks for SDK 10; the runner image ships a newer one (11 since 17.11.2026).
[TestClass]
public class BuildSdkTests
{
    [TestMethod]
    public void BuiltWithSdk10()
    {
        var sdk = typeof(BuildSdkTests).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .Single(a => a.Key == "BuildSdk").Value;
        StringAssert.StartsWith(sdk, "10.");
    }

    // Any `dotnet` the job runs outside the pinned checkout (a tool, a script, a test
    // that shells out) under a latestMajor global.json: only SDK 10 may be visible.
    [TestMethod]
    public void LatestMajorResolvesToSdk10()
    {
        var dir = Directory.CreateTempSubdirectory("sdk-select-").FullName;
        File.WriteAllText(Path.Combine(dir, "global.json"),
            """{"sdk":{"version":"10.0.100","rollForward":"latestMajor"}}""");
        var psi = new ProcessStartInfo("dotnet", "--version")
        {
            WorkingDirectory = dir,
            RedirectStandardOutput = true,
        };
        using var p = Process.Start(psi)!;
        var version = p.StandardOutput.ReadToEnd().Trim();
        p.WaitForExit();
        Directory.Delete(dir, true);
        StringAssert.StartsWith(version, "10.");
    }
}
