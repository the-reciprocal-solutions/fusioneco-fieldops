/// What `logout()` may delete from the offline DB (PENDING P-002).
///
/// `logout()` runs on a manual sign-out, the 24h session timer, the
/// session-expired dialog and any 401 — i.e. often in the middle of a shift,
/// underground. Until 2026-09-27 it called `OfflineDb.wipe()` whenever the
/// queue was empty, which also deleted work the queue no longer held: a snag
/// the server refused is kept on the phone as `local_only` (the evidence must
/// survive a rejected request) but is not queued, so the next sign-out
/// silently dropped it — and the photo files lost the only row pointing at
/// them. Same for unsent capture drafts and the conflict log.
///
/// The rule now: clear copies of server data, never unsent work. Every table
/// the DB creates must be listed in exactly one of [kSignOutWipe] or
/// [kKeptOnSignOut] (test/sign_out_wipe_test.dart enforces it), so a new
/// table is a decision, not an accident.
library;

/// One delete. [where] limits it to rows the server already has.
class SignOutWipeStep {
  const SignOutWipeStep(this.table, {this.where});

  final String table;
  final String? where;
}

/// Tables holding work that only exists on this phone — never cleared on
/// sign-out. The next sign-in on this device drains or shows them again.
const kKeptOnSignOut = <String>{
  'pending_mutations', // the offline queue itself
  'conflicts', // refused writes the technician has not seen yet
  'verification_drafts', // C2O capture drafts not yet submitted
  'tag_issue_reports', // local log of tag reports raised offline
  // The scanner's history (2026-10-06). Kept so a 24 h session expiry
  // doesn't wipe a shift's scans; every row carries its user id and is only
  // ever read back for that user, so the next person signing in sees none.
  'scan_history',
};

/// Server copies, cleared on sign-out. Rows the server does not have yet
/// (`local_only = 1`, AR progress `pending = 1`) are kept.
const kSignOutWipe = <SignOutWipeStep>[
  SignOutWipeStep('cached_entities'),
  SignOutWipeStep('sync_meta'), // includes the FR-4.4 flush lease
  SignOutWipeStep('c2o_assets'),
  SignOutWipeStep('route_packs'),
  SignOutWipeStep('snags', where: 'local_only = 0'),
  SignOutWipeStep('snag_surveys', where: 'local_only = 0'),
  // AR packs: tile *files* stay on disk; the next download re-adopts any
  // whose bytes still hash to their name instead of fetching them again.
  SignOutWipeStep('ar_manifests'),
  SignOutWipeStep('ar_tiles'),
  SignOutWipeStep('ar_features'),
  SignOutWipeStep('ar_markers', where: 'local_only = 0'),
  SignOutWipeStep('ar_corners'),
  SignOutWipeStep('ar_grid_lines'),
  SignOutWipeStep('ar_progress', where: 'pending = 0'),
  SignOutWipeStep('ar_prefs'),
];

/// The delete seam `OfflineDb` implements, so the plan is testable without
/// SQLCipher.
abstract interface class WipeExecutor {
  Future<void> deleteRows(String table, {String? where});
}

Future<void> runSignOutWipe(WipeExecutor exec) async {
  for (final step in kSignOutWipe) {
    await exec.deleteRows(step.table, where: step.where);
  }
}
