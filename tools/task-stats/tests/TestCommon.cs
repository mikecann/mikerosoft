using System;
using System.Collections.Generic;
using System.Drawing;

namespace TaskMon.Tests {

public sealed class NamedTest {
    public readonly string Name;
    public readonly Action Body;

    public NamedTest(string name, Action body) {
        Name = name;
        Body = body;
    }
}

public sealed class TestSkipException : Exception {
    public TestSkipException(string message) : base(message) {}
}

public static class AssertEx {
    public static void True(bool condition, string message) {
        if (!condition) throw new Exception(message);
    }

    public static void Equal<T>(T expected, T actual, string message) {
        if (!Equals(expected, actual)) {
            throw new Exception(string.Format("{0}. Expected <{1}> but got <{2}>.", message, expected, actual));
        }
    }

    public static void NearlyEqual(double expected, double actual, double tolerance, string message) {
        if (Math.Abs(expected - actual) > tolerance) {
            throw new Exception(string.Format("{0}. Expected <{1}> +/- {2} but got <{3}>.", message, expected, tolerance, actual));
        }
    }

    public static void SequenceEqual(float[] expected, float[] actual, string message) {
        if (expected == null || actual == null || expected.Length != actual.Length) {
            throw new Exception(message + ". Sequence lengths differ.");
        }

        for (int i = 0; i < expected.Length; i++) {
            if (Math.Abs(expected[i] - actual[i]) > 0.001f) {
                throw new Exception(string.Format("{0}. First difference at index {1}: expected <{2}> got <{3}>.", message, i, expected[i], actual[i]));
            }
        }
    }

    public static void ColorEqual(Color expected, Color actual, string message) {
        if (expected.ToArgb() != actual.ToArgb()) {
            throw new Exception(string.Format("{0}. Expected <{1}> but got <{2}>.", message, expected, actual));
        }
    }

    public static void Skip(string message) {
        throw new TestSkipException(message);
    }
}

public static class TestRunner {
    public static int Run(string suiteName, IList<NamedTest> tests) {
        Console.WriteLine("");
        Console.WriteLine("Running " + suiteName);
        Console.WriteLine(new string('-', suiteName.Length + 8));

        int failures = 0;
        int skipped = 0;
        for (int i = 0; i < tests.Count; i++) {
            var test = tests[i];
            try {
                test.Body();
                Console.ForegroundColor = ConsoleColor.Green;
                Console.WriteLine("[PASS] " + test.Name);
            } catch (TestSkipException ex) {
                skipped++;
                Console.ForegroundColor = ConsoleColor.Yellow;
                Console.WriteLine("[SKIP] " + test.Name);
                Console.ResetColor();
                Console.WriteLine("       " + ex.Message);
                continue;
            } catch (Exception ex) {
                failures++;
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine("[FAIL] " + test.Name);
                Console.ResetColor();
                Console.WriteLine("       " + ex.Message);
                continue;
            } finally {
                Console.ResetColor();
            }
        }

        Console.WriteLine("");
        if (failures == 0) {
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine(skipped == 0 ? "All tests passed." : string.Format("All tests passed with {0} skipped.", skipped));
            Console.ResetColor();
            return 0;
        }

        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine(string.Format("{0} test(s) failed.", failures));
        Console.ResetColor();
        return 1;
    }
}

} // namespace TaskMon.Tests
