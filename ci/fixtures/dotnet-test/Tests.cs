using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Fixture;

// Two unit tests run; the IntegrationTest one is excluded by the workflow's
// default test-filter. SelftestWarn=cs|msbuild (environment, read by MSBuild)
// adds a compiler / MSBuild warning that warn-as-error must turn into an error.
[TestClass]
public class Tests
{
    [TestMethod] public void One() { }
    [TestMethod] public void Two() { }
    [TestMethod, TestCategory("IntegrationTest")] public void Integration() => Assert.Fail("filtered out");
#if SELFTEST_WARN
    public void Warn() { int unused; }
#endif
}
