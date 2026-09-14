"""Helios risk engine.

Sits on the order path. Two properties dominate every design decision here:

* **Explainability.** A pre-trade decision is never a boolean. Every rule that
  was evaluated reports its observed value, its limit and its verdict, because
  "rejected" without a reason is unactionable for the trader and unauditable
  for compliance.
* **Latency.** The pre-trade gate is synchronous in front of order submission.
  Its budget is in :mod:`helios_risk.limits.engine` and is asserted by a test,
  not aspirational.
"""

__version__ = "0.1.0"
