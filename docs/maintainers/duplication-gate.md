# Duplication gate

PtcManager reuses the duplication ratchet proven in `ptc_runner` at source
commit `1a21d3f7c9ed6b6d489b8173ba215ef120b9d2b0`. The implementation is copied so
this repository's checks remain self-contained.

`mix precommit` runs `scripts/duplication_gate.sh check`. It compares ExDNA's
current report with `.duplication-baseline.json`: known clones pass, while new
duplication fails. Line-number movement does not change a clone fingerprint.

Prefer extracting shared policy. For intentionally independent code, explain
the reason immediately above one copy:

```elixir
# ex_dna:disable-for-next-line — independently owned adapter callback
def handle_cast(_request, state), do: {:noreply, state}
```

Only accept existing debt deliberately:

```bash
scripts/duplication_gate.sh bless
```

When `check` reports resolved duplication, run `bless` to lock in the smaller
baseline.
