"""PayloadContext — immutable inputs to build_payload.

Replaces the old pattern of module-level globals in
collect_metrics_payload.py that were mutated by __main__ and read
throughout build_payload. Pass this in explicitly instead.
"""

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class PayloadContext:
    """Inputs that come from the CLI — all 12 positional arguments."""
    proof_dir: str
    repo: str
    branch: str
    sha: str
    user: str
    timestamp: str
    critic_verdict_arg: Optional[str] = None
    critic_count_arg: int = 0
    user_email: str = ""
    phase: str = "all"
    gate_name: str = ""
    metrics_data_dir: str = ""

    @classmethod
    def from_argv(cls, argv):
        """Build a context from sys.argv (as passed to __main__).

        Convention: required fields are read with `argv[i]` (missing ==
        usage error, let Python raise IndexError). Optional fields are
        read via `opt(i, default)` which supplies a fallback when the
        caller omits trailing args.
        """
        def opt(i, default=""):
            return argv[i] if len(argv) > i else default
        return cls(
            # Required (argv[1..8]) — always supplied by collect-metrics.sh
            proof_dir=argv[1],
            critic_verdict_arg=argv[2] or None,
            critic_count_arg=int(argv[3] or 0),
            repo=argv[4], branch=argv[5], sha=argv[6],
            user=argv[7], timestamp=argv[8],
            # Optional (argv[9..12]) — defaulted when absent
            phase=opt(9, "all"),
            gate_name=opt(10),
            metrics_data_dir=opt(11),
            user_email=opt(12),
        )
