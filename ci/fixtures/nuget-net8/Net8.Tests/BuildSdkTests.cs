using System.Linq;
using System.Reflection;
using Microsoft.VisualStudio.TestTools.UnitTesting;

[assembly: Parallelize(Scope = ExecutionScope.MethodLevel)]

namespace Net8.Tests;

[TestClass]
public class BuildSdkTests
{
    // No global.json and only net8.0: the runner's newest SDK (10) must not build
    // this; the workflow pins SDK 8, as GitLab's dotnet/sdk:8.0 image did.
    [TestMethod]
    public void BuiltWithSdk8()
    {
        var sdk = typeof(BuildSdkTests).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .Single(a => a.Key == "BuildSdk").Value;
        StringAssert.StartsWith(sdk, "8.");
    }
}
