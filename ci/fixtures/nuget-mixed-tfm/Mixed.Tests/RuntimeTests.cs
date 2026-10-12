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
}
