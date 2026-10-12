using Microsoft.VisualStudio.TestTools.UnitTesting;

[assembly: Parallelize(Scope = ExecutionScope.MethodLevel)]

namespace Mixed.Tests;

[TestClass]
public class RuntimeTests
{
    [TestMethod]
    public void RunsOnTheTargetFrameworkRuntime()
    {
#if NET10_0
        Assert.AreEqual(10, Mixed.Lib.Runtime.Major);
#elif NET8_0
        Assert.AreEqual(8, Mixed.Lib.Runtime.Major);
#endif
    }

    // selftest.yml passes these as the workflow's test-env; the ECR value also
    // makes the workflow log in to ECR (nothing is pulled).
    [TestMethod]
    public void SeesTestEnv()
    {
        Assert.AreEqual("from-test-env", System.Environment.GetEnvironmentVariable("SELFTEST_TEST_ENV"));
        StringAssert.StartsWith(System.Environment.GetEnvironmentVariable("SELFTEST_ECR_IMAGE") ?? "",
            "515260921971.dkr.ecr.us-west-2.amazonaws.com/");
    }

    // No global.json: the workflow pins the SDK of the highest target framework.
    [TestMethod]
    public void BuiltWithTheSdkOfTheHighestTargetFramework() =>
        StringAssert.StartsWith(Mixed.Lib.Runtime.BuildSdk, "10.");
}
