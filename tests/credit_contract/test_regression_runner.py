"""Runner-oracle tests using fake processes only; no VCS results are generated."""

from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import re
import shlex
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "run_credit_regression", ROOT / "sim/run_credit_regression.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)

FAKE_SIMULATOR = r'''
import sys, time
mode = sys.argv[1]
test = next(x.split("=", 1)[1] for x in sys.argv if x.startswith("+UVM_TESTNAME="))
if mode == "timeout":
    time.sleep(1)
injection = test == "i2c_credit_error_test"
exhaustion = test == "i2c_credit_exhaustion_test"
count = 3 if injection else (1 if exhaustion else 0)
if mode == "diagnostic_error":
    print("UVM_ERROR @ 0: [TEST] unexpected failure despite a zero summary")
if mode == "accounting_error":
    print("TBI-4: conservation mismatch")
if exhaustion:
    print("UVM_ERROR @ 0: [CBT_DRV] TBI-5 diagnostic timeout: pending DATA aborted without transmission")
    for invariant in (1, 2, 3, 6):
        print("TBI-%d Violations : 0" % invariant)
    print("TBI-4 Residual : 0")
for i in range(3 if injection else 0):
    tag = "TBI-2" if mode == "wrong_injection" and i == 0 else "TBI-1"
    print("UVM_ERROR @ %d: [CREDIT_MON] %s VIOLATION (completion-time diagnostic): attempted=1 current_available=0 (launch budget not observed)" % (i, tag))
failed = mode == "first_failure" and test == "i2c_credit_sanity_test"
if mode != "missing_marker":
    suffix = " (observed exactly 3 TBI-1 violations)" if injection else ""
    if exhaustion:
        suffix = " (observed exactly 1 expected TBI-5 timeout; no DATA launch)"
    print("TEST STATUS: " + ("FAILED" if failed else "PASSED") + suffix)
if mode != "missing_summary":
    print("UVM_ERROR : %d" % count)
    print("UVM_FATAL : %d" % (mode == "fatal"))
sys.exit(2 if mode == "nonzero" else 0)
'''


class RegressionRunnerTest(unittest.TestCase):
    def exhaustion_output(self, diagnostic=None):
        diagnostic = diagnostic or (
            "[CBT_DRV] TBI-5 diagnostic timeout: pending DATA aborted without transmission")
        return "\n".join(
            ["UVM_ERROR @ 0: " + diagnostic,
             "TEST STATUS: PASSED (observed exactly 1 expected TBI-5 timeout; no DATA launch)",
             "UVM_ERROR : 1", "UVM_FATAL : 0", "TBI-4 Residual : 0"]
            + ["TBI-{} Violations : 0".format(index) for index in (1, 2, 3, 6)])

    def injection_output(self, diagnostic=None):
        diagnostic = diagnostic or (
            "[CREDIT_MON] TBI-1 VIOLATION (completion-time diagnostic): "
            "attempted=1 current_available=0 (launch budget not observed)")
        return "\n".join(
            ["UVM_ERROR @ {}: {}".format(i, diagnostic) for i in range(3)]
            + ["TEST STATUS: PASSED (observed exactly 3 TBI-1 violations)",
               "UVM_ERROR : 3", "UVM_FATAL : 0"])

    def run_fake(self, mode="pass", tests=None, iterations=1, seed_start=1, timeout=5):
        with tempfile.TemporaryDirectory(prefix="credit_runner_unit_") as directory:
            with redirect_stdout(io.StringIO()):
                summary = RUNNER.run_suite(
                    [sys.executable, "-B", "-c", FAKE_SIMULATOR, mode],
                    tests or [RUNNER.TESTS[0]], iterations, seed_start, directory, timeout)
            self.assertEqual(len(list(Path(directory).rglob("summary.json"))), 1)
            self.assertEqual(len(list(Path(directory).rglob("summary.csv"))), 1)
            return summary

    def test_first_failure_is_not_hidden_by_last_pass(self):
        result = self.run_fake("first_failure", [RUNNER.TESTS[0], RUNNER.TESTS[-1]])
        self.assertEqual([row["status"] for row in result["results"]], ["FAIL", "PASS"])
        self.assertEqual(result["failures"], 1)

    def test_cli_returns_failure_when_first_case_fails_and_last_passes(self):
        with tempfile.TemporaryDirectory(prefix="credit_runner_cli_unit_") as directory:
            with redirect_stdout(io.StringIO()):
                status = RUNNER.main([
                    "--sim-command", shlex.join(
                        [sys.executable, "-B", "-c", FAKE_SIMULATOR, "first_failure"]),
                    "--tests", RUNNER.TESTS[0], RUNNER.TESTS[-1], "--iterations", "1",
                    "--output-dir", directory,
                ])
        self.assertEqual(status, 1)

    def test_nonzero_exit_rejects_a_passing_marker(self):
        self.assertEqual(self.run_fake("nonzero")["failures"], 1)

    def test_error_diagnostic_rejects_a_zero_error_summary(self):
        self.assertEqual(self.run_fake("diagnostic_error")["failures"], 1)

    def test_fatal_summary_rejects_a_passing_marker(self):
        self.assertEqual(self.run_fake("fatal")["failures"], 1)

    def test_accounting_diagnostic_rejects_a_passing_marker(self):
        self.assertEqual(self.run_fake("accounting_error")["failures"], 1)

    def test_missing_status_marker_fails_closed(self):
        self.assertEqual(self.run_fake("missing_marker")["failures"], 1)

    def test_missing_uvm_summary_fails_closed(self):
        self.assertEqual(self.run_fake("missing_summary")["failures"], 1)

    def test_exact_injection_is_reported_separately(self):
        result = self.run_fake(tests=[RUNNER.ERROR_TEST])
        self.assertEqual(result["failures"], 0)
        self.assertEqual(result["expected_injection_passes"], 1)
        self.assertEqual(result["results"][0]["status"], "EXPECTED_INJECTION_PASS")

    def test_exact_exhaustion_timeout_is_reported_separately(self):
        result = self.run_fake(tests=[RUNNER.EXHAUSTION_TEST])
        self.assertEqual(result["failures"], 0)
        self.assertEqual(result["expected_timeout_passes"], 1)
        self.assertEqual(result["results"][0]["status"], "EXPECTED_TIMEOUT_PASS")

    def test_actual_driver_timeout_category_matches_only_exhaustion(self):
        source = (ROOT / "src/agent/i2c_credit_master_driver.sv").read_text()
        message = re.search(r'"(TBI-5 diagnostic timeout:[^"\n]+)"', source).group(1)
        output = self.exhaustion_output("[CBT_DRV] " + message)
        self.assertEqual(RUNNER.assess_output(RUNNER.EXHAUSTION_TEST, output, 0)["status"],
                         "EXPECTED_TIMEOUT_PASS")
        for test in set(RUNNER.TESTS) - {RUNNER.EXHAUSTION_TEST}:
            with self.subTest(test=test):
                self.assertEqual(RUNNER.assess_output(test, output, 0)["status"], "FAIL")

    def test_exhaustion_requires_the_exact_reporter_and_timeout_text(self):
        for diagnostic in (
            "[OTHER] TBI-5 diagnostic timeout: pending DATA aborted without transmission",
            "[CBT_DRV] TBI-5 diagnostic timeout: pending DATA transmitted",
            "[CBT_DRV] unrelated failure", "[CREDIT_MON] TBI-5 VIOLATION",
        ):
            with self.subTest(diagnostic=diagnostic):
                self.assertEqual(RUNNER.assess_output(
                    RUNNER.EXHAUSTION_TEST, self.exhaustion_output(diagnostic), 0)["status"], "FAIL")

    def test_exhaustion_rejects_missing_extra_or_inconsistent_errors(self):
        output = self.exhaustion_output()
        variants = (
            "\n".join(line for line in output.splitlines() if not line.startswith("UVM_ERROR @")),
            output + "\nUVM_ERROR @ 1: [CBT_DRV] TBI-5 diagnostic timeout: pending DATA aborted without transmission",
            output + "\nUVM_ERROR @ 1: [TEST] unexpected failure",
            output.replace("UVM_ERROR : 1", "UVM_ERROR : 0"),
            output.replace("UVM_ERROR : 1", "UVM_ERROR : 2"),
            output.replace("UVM_FATAL : 0", "UVM_FATAL : 1"),
        )
        for candidate in variants:
            with self.subTest(candidate=candidate):
                self.assertEqual(RUNNER.assess_output(RUNNER.EXHAUSTION_TEST, candidate, 0)["status"], "FAIL")

    def test_exhaustion_requires_exact_oracle_and_monitor_results(self):
        output = self.exhaustion_output()
        variants = [
            output.replace(" (observed exactly 1 expected TBI-5 timeout; no DATA launch)", ""),
            output.replace("no DATA launch", "DATA launched"),
            output.replace("expected TBI-5 timeout", "unexpected TBI-5 timeout"),
            output.replace("TBI-4 Residual : 0", ""),
            output.replace("TBI-1 Violations : 0", ""),
            output.replace("TBI-4 Residual : 0", "TBI-4 Residual : -1"),
        ]
        variants.extend(output + "\nTBI-{} Violations : 1".format(index) for index in range(1, 7))
        for candidate in variants:
            with self.subTest(candidate=candidate):
                self.assertEqual(RUNNER.assess_output(RUNNER.EXHAUSTION_TEST, candidate, 0)["status"], "FAIL")

    def test_expected_driver_timeout_does_not_waive_process_failures(self):
        output = self.exhaustion_output()
        self.assertEqual(RUNNER.assess_output(RUNNER.EXHAUSTION_TEST, output, 2)["status"], "FAIL")
        self.assertEqual(RUNNER.assess_output(RUNNER.EXHAUSTION_TEST, output, 0, timed_out=True)["status"], "FAIL")

    def test_injection_does_not_allow_other_error_categories(self):
        self.assertEqual(self.run_fake("wrong_injection", [RUNNER.ERROR_TEST])["failures"], 1)

    def test_injection_requires_all_expected_diagnostics(self):
        output = "TEST STATUS: PASSED (observed exactly 3 TBI-1 violations)\n"
        output += "UVM_ERROR : 3\nUVM_FATAL : 0\n"
        self.assertEqual(RUNNER.assess_output(RUNNER.ERROR_TEST, output, 0)["status"], "FAIL")

    def test_nonzero_tbi_counter_cannot_hide_behind_zero_error_summary(self):
        output = "TEST STATUS: PASSED\nUVM_ERROR : 0\nUVM_FATAL : 0\n"
        output += "║ TBI-1 Violations : 1 ║\n"
        self.assertEqual(RUNNER.assess_output(RUNNER.TESTS[0], output, 0)["status"], "FAIL")

    def test_signed_conservation_residual_cannot_hide_behind_zero_error_summary(self):
        for residual in (-1, 1):
            output = "TEST STATUS: PASSED\nUVM_ERROR : 0\nUVM_FATAL : 0\n"
            output += "║ TBI-4 Residual : {} ║\n".format(residual)
            with self.subTest(residual=residual):
                self.assertEqual(RUNNER.assess_output(RUNNER.TESTS[0], output, 0)["status"], "FAIL")

    def test_unexpected_injection_tbi_counter_fails(self):
        output = self.injection_output() + "\n║ TBI-2 Violations : 1 ║"
        self.assertEqual(RUNNER.assess_output(RUNNER.ERROR_TEST, output, 0)["status"], "FAIL")

    def test_timeout_is_a_failure(self):
        self.assertEqual(self.run_fake("timeout", timeout=0.02)["failures"], 1)

    def test_mirrored_outputs_do_not_double_count_expected_errors(self):
        output = self.injection_output()
        merged = RUNNER.merge_outputs(output, output)
        self.assertEqual(RUNNER.assess_output(RUNNER.ERROR_TEST, merged, 0)["status"],
                         "EXPECTED_INJECTION_PASS")

    def test_actual_monitor_category_matches_the_narrow_injection_waiver(self):
        source = (ROOT / "src/agent/i2c_credit_monitor.sv").read_text()
        template = re.search(r'"(TBI-1 VIOLATION[^"\n]+)"', source).group(1)
        diagnostic = "[CREDIT_MON] " + template.replace("%0d", "{}", 2).format(1, 0)
        output = self.injection_output(diagnostic)
        self.assertEqual(RUNNER.assess_output(RUNNER.ERROR_TEST, output, 0)["status"],
                         "EXPECTED_INJECTION_PASS")
        self.assertEqual(RUNNER.assess_output(RUNNER.TESTS[0], output, 0)["status"], "FAIL")

    def test_injection_waiver_rejects_other_reporters_or_budget_values(self):
        expected = "[CREDIT_MON] TBI-1 VIOLATION (completion-time diagnostic): attempted=1 current_available=0 (launch budget not observed)"
        invalid = (
            expected.replace("CREDIT_MON", "OTHER"),
            expected.replace("attempted=1", "attempted=2"),
            expected.replace("current_available=0", "current_available=-1"),
            expected.replace("current_available=0", "current_available=1"),
            "[CREDIT_MON] TBI-1 VIOLATION: unrelated failure",
            "[CREDIT_MON] TBI-1 completion-time diagnostic: unrelated failure",
        )
        for diagnostic in invalid:
            with self.subTest(diagnostic=diagnostic):
                self.assertEqual(RUNNER.assess_output(
                    RUNNER.ERROR_TEST, self.injection_output(diagnostic), 0)["status"], "FAIL")

    def test_console_only_error_is_not_hidden_by_native_log(self):
        native = "TEST STATUS: PASSED\nUVM_ERROR : 0\nUVM_FATAL : 0"
        console = "UVM_ERROR @ 0: [WRAPPER] unexpected diagnostic\n" + native
        merged = RUNNER.merge_outputs(native, console)
        self.assertEqual(RUNNER.assess_output(RUNNER.TESTS[0], merged, 0)["status"], "FAIL")

    def test_six_by_fifteen_fake_runs_have_explicit_seeds_and_credit_flag(self):
        result = self.run_fake(tests=list(RUNNER.TESTS), iterations=15, seed_start=101)
        self.assertEqual(result["runs"], 90)
        self.assertEqual(result["failures"], 0)
        self.assertEqual(result["expected_injection_passes"], 15)
        self.assertEqual(result["expected_timeout_passes"], 15)
        for test in RUNNER.TESTS:
            rows = [row for row in result["results"] if row["test"] == test]
            self.assertEqual([row["seed"] for row in rows], list(range(101, 116)))
            for row in rows:
                self.assertIn("+CREDIT_MODE", row["command"])
                self.assertIn("+ntb_random_seed={}".format(row["seed"]), row["command"])

    def test_invalid_inputs_are_rejected_before_running(self):
        for iterations, seed in ((0, 1), (1, 0), (2, 2147483647)):
            with self.subTest(iterations=iterations, seed=seed):
                with self.assertRaises(ValueError):
                    RUNNER.run_suite(["unused"], [RUNNER.TESTS[0]], iterations, seed,
                                     Path("unused"), 1)
        with self.assertRaises(ValueError):
            RUNNER.run_suite(["unused", "+ntb_random_seed_automatic"], [RUNNER.TESTS[0]],
                             1, 1, Path("unused"), 1)


if __name__ == "__main__":
    unittest.main()
