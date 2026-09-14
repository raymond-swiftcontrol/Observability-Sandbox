"""Helios quant engine.

Research and backtesting service. Everything in here is held to one rule that
overrides convenience: a computation may only see information that existed at
the timestamp it is labelled with. The modules that are easiest to get wrong —
``data`` (as-of filters), ``features`` (causality), ``featurestore``
(read-time as-of enforcement) and ``backtest`` (fill timing) — each carry their
own tests for that property.
"""

__version__ = "0.1.0"
