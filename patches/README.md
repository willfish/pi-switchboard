# Cowboy 2.14.0 parser patch

`cowboy-2.14.0-complete-input-limits.patch` enforces the existing request-line,
header-name and header-value limits when a delimiter is already buffered.
Cowboy's LF match offset includes the preceding CR, so the completed line/value
check compares against `MaxLength + 1`. The colon offset is the name length.
Limits remain inclusive. Incomplete request lines and values allow one extra
byte only when it is a trailing CR, so splitting CRLF does not reject otherwise
valid boundary-sized input. Other oversized incomplete input is still rejected.
Leading header-value whitespace is handled by Cowboy before its value limit check.

Run local builds and tests through `direnv exec . scripts/rebar3-patched ...`
(for example, `eunit`, `ct`, or `release`). Locked dependency sources must already
be present. The runner verifies/applies the patch and cleans dependency BEAMs
before invoking Rebar, which otherwise can reuse unpatched compiled dependencies.
Do not use an unpatched direct Rebar build as release or verification evidence.

Both Nix release and hub tests use `nix/cowboy-checkouts.nix`, which patches a
copy of the same hash-locked dependency output without changing dependency
versions or acquisition hashes. `scripts/patch-cowboy.sh` accepts only the exact
original or exact patched source digest. Unknown or partially patched sources
fail closed. `scripts/test-patch-cowboy.sh` checks application, repeat application
and rejection without modification of mismatched input.

Header counts track completed lines rather than distinct map keys, so duplicate
names consume the existing count limit. Before each duplicate-value merge,
Cowboy checks the combined value size including its two-byte separator. This
bounds retained aggregate values without allocating an oversized merged binary;
normal comma joins and Cookie semicolon joins retain their existing semantics.
The same inclusive value limit applies to both individual and merged values.
