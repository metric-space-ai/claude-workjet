# Workjet-Postmortem — greppy-0.3.0-Session, 2026-07-28

Quelle: vollständiges Session-Transkript (99 MB), mechanisch nach Markern
durchsucht; jede Zahl ist ein grep-Count über die JSONL, jeder Fall wurde in
der Session direkt beobachtet. Ziel: Umbau der Wrapper, damit keiner der
Fehler wieder passieren kann.

## Die zehn Probleme, mit Fix im Wrapper

**1. Briefs haben Worker aus ihren Worktrees gelotst.** Jeder Brief sagte
„Work in /Users/michaelwelsch/greppy-030" — Worker folgen dem Brief, nicht dem
cwd. Folgen: Uncommittete Orchestrator-Edits im Hauptcheckout zweimal von
Worker-Git-Operationen zurückgesetzt; 90 Minuten path-Arbeit „verloren" (lag
uncommittet im Hauptcheckout); Release-Build gegen einen live editierten Baum;
Whitelists faktisch unverbindlich. Marker: `main checkout is dirty` 5×.
**Fix:** Der Launcher verlässt sich nicht auf den Brief: er injiziert selbst
eine Präambel vor jeden Prompt („You are in an isolated worktree at $PWD.
Never cd to another checkout.") UND prüft nach dem Lauf, ob der Hauptcheckout
sich verändert hat — wenn ja, gilt der Lauf als FAILED, laut.

**2. Brief-Lesen mit stillem Fallback.** `$(cat brief || echo MISSING)` machte
aus einer beim /tmp-Aufräumen gelöschten Datei den Sieben-Byte-Auftrag
„MISSING" — Sol baute daraufhin 40 Minuten lang Missing-Symbol-Recovery, und
der Orchestrator beschuldigte fälschlich den Worker.
**Fix:** `claude-agent --brief FILE` statt Shell-Substitution: der Wrapper
prüft Existenz und Mindestlänge selbst und verweigert den Start sonst.

**3. Probe-Falschnegative haben gesunde Läufe getötet.** `probe timed out` 9×
(25 s/60 s), während derselbe Wrapper Minuten später in 6,1 s antwortete;
`TASK_FAILED` 13×, `PRIMARY_UNAVAILABLE` 25×.
**Fix:** Probe mit 3× Retry und Backoff, Standard-Timeout 120 s, Probe über
exakt denselben Pfad wie der Task, Unterscheidung auth vs. timeout im
Fehlertext, und ein Last-Good-Cache (Probe innerhalb von 10 min nicht
wiederholen).

**4. Auth-Ablauf ohne Selbstheilung.** `auth_unavailable` 6× — und nach dem
Browser-Relogin des Users servierte der Proxy weiter den alten Zustand, bis
jemand manuell `brew services restart cliproxyapi` lief.
**Fix:** Der Wrapper erkennt `auth_unavailable`, vergleicht mtime der
Token-Datei mit dem Proxy-Start und startet den Proxy einmal selbst neu,
bevor er aufgibt; erst danach die User-Anweisung.

**5. Die Opus-Rückfallstufe war nie funktionsfähig.** `fallback not available
(token file? quota?)` 6× — die dokumentierte sichere Substitution griff kein
einziges Mal (Token-Datei fehlt seit jeher).
**Fix:** `claude-agent doctor`: prüft jede Sprosse der Kette (sol, kimi,
minimax, opus-Token) auf Knopfdruck, und der Launcher warnt bei jedem Start
laut, wenn eine dokumentierte Sprosse tot ist — nicht erst, wenn sie
gebraucht wird.

**6. Das 90-Minuten-Limit tötete ohne Wertsicherung.** `exceeded 5400` 5×,
`retaining worktree` 4× — Timeout-Läufe hinterließen leere Berichte und (im
Worktree) keine Commits; Arbeit überlebte nur dort, wo sie regelwidrig im
Hauptcheckout lag.
**Fix:** (a) Bei Timeout committet der Wrapper selbst den Worktree-Stand als
`wip:`-Commit und legt einen Diff-Report in das Run-Verzeichnis — nichts ist
mehr unsichtbar. (b) Die Green-Slices-Pflicht („commit in green slices, a
timeout must still land value") wandert aus den Einzelbriefs in die
Standard-Präambel des Launchers.

**7. Keine Lebendbeobachtung während der Läufe.** Fire-and-forget ohne
PID-Wahrheit; ein Zombie-Sol (Marker `zombie` 8×) überlebte musterbasierte
Kills, weil der Prozessname nach exec nicht mehr passte, und schrieb über eine
Stunde in Dateien — drei Patch-Versuche korrumpiert. `claude-run`/`claude-jobs`
entstanden erst mitten in der Session als Notbehelf.
**Fix:** PID-Datei, Heartbeat (mtime-Touch alle 60 s) und Exit-Marker werden
Kernfunktion von `claude-agent` selbst; Kill ausschließlich über die
PID-Datei, nie über Prozessmuster.

**8. Timeout-Läufe ohne Bericht.** Leere stdout-Dateien zwangen den
Orchestrator zur Baum-Forensik, um zu erfahren, was ein Worker überhaupt tat.
**Fix:** Der Wrapper führt ein eigenes Lauf-Journal, unabhängig vom Modell:
Brief-Hash beim Start, alle 10 min `git diff --stat`-Schnappschuss des
Worktrees, Endzustand. Ein Lauf ohne Modell-Bericht hat dann trotzdem eine
Geschichte.

**9. „Grün" ohne Repo-Wächter.** Ein Worker führte wörtlich das verbotene
Muster „Accepted for agent ergonomics — no-op" neu ein, ein anderer ließ einen
Zähler eine andere Menge zählen als die Trefferliste — beides von den
Abnahmen des Briefs nicht gefangen, erst vom Orchestrator.
**Fix:** Optionaler Repo-Hook `.workjet/checks.sh` (bei greppy:
`cargo test --test prompt_contract`), den der Wrapper nach jedem Lauf
ausführt, bevor er einen Erfolg meldet.

**10. Der Dirty-Check war richtig, aber zirkulär.** `refusing to start` 18× —
korrektes Verhalten, aber die Verschmutzung stammte überwiegend von Workern
selbst (Problem 1). Mit Fix 1 bleibt der Check unverändert bestehen.

## Rangfolge für den Umbau

1 und 2 zuerst (sie haben den meisten Schaden verursacht), dann 6+7+8 (ein
zusammenhängender Umbau des Run-Lebenszyklus), dann 3+4+5 (Probe/Auth), 9
zuletzt. Alle Fixes liegen im Wrapper — kein Fix verlangt Wohlverhalten der
Modelle.
