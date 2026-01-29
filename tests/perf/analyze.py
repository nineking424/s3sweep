#!/usr/bin/env python3
"""
analyze.py - Parse and analyze s3sweep performance test results

Reads result files from benchmark.sh, stress.sh, and resource_monitor.sh
and generates summary reports with pass/warn/fail status.
"""

import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple
from dataclasses import dataclass
from datetime import datetime


@dataclass
class TestResult:
    """Represents a single test result"""
    test_id: str
    test_name: str
    metric: str
    value: float
    unit: str
    baseline: float
    status: str

    @property
    def deviation_pct(self) -> float:
        """Calculate percentage deviation from baseline"""
        if self.baseline == 0:
            return 0.0
        return ((self.value - self.baseline) / self.baseline) * 100


class ResultAnalyzer:
    """Analyzes performance test results"""

    # Performance baselines
    BASELINES = {
        'PERF-001': {'throughput': 50, 'unit': 'files/sec'},
        'PERF-002': {'throughput': 10, 'unit': 'files/sec'},
        'PERF-003': {'throughput': 100, 'unit': 'files/sec'},
        'PERF-004': {'throughput': 300, 'unit': 'files/sec'},
        'PERF-006': {'latency': 100, 'unit': 'ms'},
        'PERF-007': {'latency': 500, 'unit': 'ms'},
        'PERF-008': {'latency': 5000, 'unit': 'ms'},
        'PERF-009': {'cpu': 1, 'unit': '%'},
        'PERF-010': {'memory': 50, 'unit': 'MB'},
        'PERF-011': {'memory': 200, 'unit': 'MB'},
        'PERF-012': {'cpu': 1, 'unit': '%'},
        'PERF-013': {'cpu': 80, 'unit': '%'},
        'PERF-014': {'memory_growth': 10, 'unit': 'MB'},
    }

    def __init__(self):
        self.results: List[TestResult] = []

    def parse_result_line(self, line: str) -> TestResult | None:
        """Parse a single result line"""
        # Format: [STATUS] TEST_NAME - METRIC: VALUE UNIT (baseline: BASELINE)
        pattern = r'\[(\w+)\]\s+([A-Z-0-9]+)\s*-?\s*(.+?):\s+([\d.]+)\s+(\w+/?[\w]*)\s*(?:\(baseline:\s*([\d.]+|N/A)\))?'
        match = re.match(pattern, line)

        if not match:
            return None

        status, test_id, metric, value_str, unit, baseline_str = match.groups()

        try:
            value = float(value_str)
            baseline = float(baseline_str) if baseline_str and baseline_str != 'N/A' else 0.0

            return TestResult(
                test_id=test_id,
                test_name=test_id,
                metric=metric.strip(),
                value=value,
                unit=unit,
                baseline=baseline,
                status=status
            )
        except (ValueError, TypeError):
            return None

    def parse_file(self, filepath: Path):
        """Parse a result file"""
        if not filepath.exists():
            print(f"Warning: {filepath} not found", file=sys.stderr)
            return

        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('['):
                    result = self.parse_result_line(line)
                    if result:
                        self.results.append(result)

    def generate_summary_table(self) -> str:
        """Generate a markdown summary table"""
        lines = []

        lines.append("# S3Sweep Performance Test Summary\n")
        lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        lines.append("")

        # Group by test ID
        test_groups: Dict[str, List[TestResult]] = {}
        for result in self.results:
            if result.test_id not in test_groups:
                test_groups[result.test_id] = []
            test_groups[result.test_id].append(result)

        # Summary statistics
        total_tests = len(test_groups)
        passed = sum(1 for results in test_groups.values()
                     if all(r.status == 'PASS' for r in results))
        warned = sum(1 for results in test_groups.values()
                     if any(r.status == 'WARN' for r in results))
        failed = sum(1 for results in test_groups.values()
                     if any(r.status == 'FAIL' for r in results))

        lines.append("## Summary")
        lines.append("")
        lines.append(f"- **Total Tests**: {total_tests}")
        lines.append(f"- **Passed**: {passed} ✅")
        lines.append(f"- **Warned**: {warned} ⚠️")
        lines.append(f"- **Failed**: {failed} ❌")
        lines.append("")

        # Detailed results
        lines.append("## Detailed Results")
        lines.append("")
        lines.append("| Test ID | Metric | Value | Unit | Baseline | Deviation | Status |")
        lines.append("|---------|--------|-------|------|----------|-----------|--------|")

        for test_id in sorted(test_groups.keys()):
            for result in test_groups[test_id]:
                deviation = f"{result.deviation_pct:+.1f}%" if result.baseline > 0 else "N/A"
                status_icon = self._get_status_icon(result.status)
                baseline_str = f"{result.baseline:.2f}" if result.baseline > 0 else "N/A"

                lines.append(
                    f"| {result.test_id} | {result.metric} | {result.value:.2f} | "
                    f"{result.unit} | {baseline_str} | {deviation} | {status_icon} |"
                )

        lines.append("")

        # Performance category analysis
        lines.append("## Performance Analysis")
        lines.append("")

        throughput_results = [r for r in self.results if 'throughput' in r.metric.lower()]
        if throughput_results:
            lines.append("### Throughput")
            avg_throughput = sum(r.value for r in throughput_results) / len(throughput_results)
            lines.append(f"- Average: {avg_throughput:.2f} files/sec")
            lines.append("")

        latency_results = [r for r in self.results if 'latency' in r.metric.lower()]
        if latency_results:
            lines.append("### Latency")
            avg_latency = sum(r.value for r in latency_results) / len(latency_results)
            lines.append(f"- Average: {avg_latency:.2f} ms")
            lines.append("")

        memory_results = [r for r in self.results if 'memory' in r.metric.lower()]
        if memory_results:
            lines.append("### Memory")
            avg_memory = sum(r.value for r in memory_results) / len(memory_results)
            lines.append(f"- Average: {avg_memory:.2f} MB")
            lines.append("")

        cpu_results = [r for r in self.results if 'cpu' in r.metric.lower()]
        if cpu_results:
            lines.append("### CPU")
            avg_cpu = sum(r.value for r in cpu_results) / len(cpu_results)
            lines.append(f"- Average: {avg_cpu:.2f}%")
            lines.append("")

        return "\n".join(lines)

    @staticmethod
    def _get_status_icon(status: str) -> str:
        """Get status icon"""
        icons = {
            'PASS': '✅ PASS',
            'WARN': '⚠️ WARN',
            'FAIL': '❌ FAIL'
        }
        return icons.get(status, status)


def main():
    """Main entry point"""
    analyzer = ResultAnalyzer()

    # Parse all result files
    result_dir = Path('/tmp')

    result_files = [
        result_dir / 's3sweep_perf_results.txt',
        result_dir / 's3sweep_stress_results.txt',
        result_dir / 's3sweep_resource_results.txt'
    ]

    for filepath in result_files:
        analyzer.parse_file(filepath)

    if not analyzer.results:
        print("No results found. Run performance tests first:", file=sys.stderr)
        print("  ./benchmark.sh", file=sys.stderr)
        print("  ./stress.sh", file=sys.stderr)
        print("  ./resource_monitor.sh", file=sys.stderr)
        return 1

    # Generate and print summary
    summary = analyzer.generate_summary_table()
    print(summary)

    # Save to file
    output_file = result_dir / 's3sweep_perf_summary.md'
    with open(output_file, 'w') as f:
        f.write(summary)

    print(f"\nSummary saved to: {output_file}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
