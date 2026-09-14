// This matrix is emitted by the runner so partial acceptance stays explicit.
// It is a coverage inventory, not a list of skipped test cases.
export const remainingScenarios = [];
// Native Bun closes the held downstream connections before response release.
// These cases do not deliver uncooperative callbacks into the runtime; those
// fences require separate unit evidence. Upstream effects are not rolled back.
export const platformGates = [
  'same runtime suite executed natively on Apple Silicon Darwin, including PTY cleanup',
];
export const consumerGates = [
  'actual dotfiles module/generated wrapper source and artifact evidence: offline, discovery suppression, explicit extension list excludes Switchboard, no second load path, selected Pi and agent directory, conditional branches and argument forwarding',
  'actual wrapper, credential and activation evidence remains separately authorized; never execute or source the credential wrapper or load its real extensions in standalone fixtures',
];
