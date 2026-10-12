using System.Linq;

namespace Mixed.Lib;

public static class Runtime
{
    public static int Major => System.Environment.Version.Major;

    public static string BuildSdk => typeof(Runtime).Assembly
        .GetCustomAttributes(typeof(System.Reflection.AssemblyMetadataAttribute), false)
        .Cast<System.Reflection.AssemblyMetadataAttribute>()
        .Single(a => a.Key == "BuildSdk").Value!;
}
