// "Inbox handling" (the Inbox's ⋯ menu, #4524): the Inbox's own handling switches, one dialog beside Rules and Folders.
// Today it holds forwarding a message linked to a running task to that task's owner; the page in #4501 grows from it.

import { useEffect, useId, useState } from "react";
import { errorText } from "../../lib/api";
import { loadInboxSettings, saveInboxSettings, type InboxSettings } from "../../lib/inbox-settings";
import { t } from "../../i18n";
import { Button, Dialog, Switch, toast } from "../../ui/atoms";

export function InboxHandlingDialog({ onClose }: { onClose: () => void }) {
  const [saved, setSaved] = useState<InboxSettings | null>(null);
  const [failed, setFailed] = useState("");
  const [forward, setForward] = useState(false);
  const [busy, setBusy] = useState(false);
  const id = useId();
  useEffect(() => {
    let live = true;
    loadInboxSettings().then(
      (s) => { if (live) { setSaved(s); setForward(s.forward_to_tasks); } },
      (e) => { if (live) setFailed(errorText(e)); },
    );
    return () => { live = false; };
  }, []);
  const save = async () => {
    setBusy(true);
    try {
      await saveInboxSettings({ forward_to_tasks: forward });
      toast(t("inbox-handling.saved"), "ok");
      onClose();
    } catch (e) {
      toast(t("inbox-handling.save_failed", { error: errorText(e) }), "error");
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog open onClose={onClose} title={t("inbox-handling.title")} width={460}
      footer={
        <>
          <Button tone="quiet" onClick={onClose}>{t("common.cancel")}</Button>
          <Button tone="primary" busy={busy} disabled={!saved} onClick={() => void save()}>{t("common.save")}</Button>
        </>
      }>
      <div className="flex items-start gap-3" data-inbox-handling>
        <span className="min-w-0 flex-1">
          <span className="block text-[13px] font-medium text-ink">{t("inbox-handling.forward_title")}</span>
          <span id={`${id}-about`} className="mt-0.5 block text-[12px] leading-relaxed text-ink-3">{t("inbox-handling.forward_about")}</span>
        </span>
        <Switch on={forward} onChange={setForward} disabled={!saved} label={t("inbox-handling.forward_title")} describedBy={`${id}-about`} />
      </div>
      {failed && <p className="mt-3 text-[12px] text-red" role="alert">{t("inbox-handling.load_failed", { error: failed })}</p>}
    </Dialog>
  );
}
