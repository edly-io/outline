import { subMinutes } from "date-fns";
import { observer } from "mobx-react";
import { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import type { DocumentPermission } from "@shared/types";
import { UserRole } from "@shared/types";
import type Document from "~/models/Document";
import ConfirmationDialog from "~/components/ConfirmationDialog";
import useCurrentUser from "~/hooks/useCurrentUser";
import usePolicy from "~/hooks/usePolicy";
import useStores from "~/hooks/useStores";
import { client } from "~/utils/ApiClient";
import Logger from "~/utils/Logger";

/** Only documents published this recently prompt, so older ones stay quiet. */
const PROMPT_WITHIN_MINUTES = 10;

type MembershipsResponse = {
  data: {
    memberships: {
      userId: string;
      sourceId?: string | null;
      permission: DocumentPermission;
    }[];
    users: { id: string; name: string; role: UserRole }[];
  };
};

type Viewer = { id: string; name: string; permission: DocumentPermission };

type Props = {
  document: Document;
};

/**
 * Viewers (external users such as clients) never inherit access to nested
 * documents. When a nested document is published below a parent that is shared
 * with viewers, ask its author whether to share it with those viewers too.
 */
function ShareWithViewersPrompt({ document }: Props) {
  const { t } = useTranslation();
  const user = useCurrentUser();
  const can = usePolicy(document);
  const { dialogs } = useStores();
  const { parentDocumentId, publishedAt } = document;
  const isAuthor = document.createdBy?.id === user.id;

  useEffect(() => {
    if (
      !parentDocumentId ||
      !publishedAt ||
      !isAuthor ||
      !can.manageUsers ||
      new Date(publishedAt) < subMinutes(new Date(), PROMPT_WITHIN_MINUTES) ||
      hasPrompted(document.id)
    ) {
      return;
    }

    let cancelled = false;

    const check = async () => {
      const [parent, current] = await Promise.all([
        client.post<MembershipsResponse>("/documents.memberships", {
          id: parentDocumentId,
          limit: 100,
        }),
        client.post<MembershipsResponse>("/documents.memberships", {
          id: document.id,
          limit: 100,
        }),
      ]);
      if (cancelled) {
        return;
      }

      const alreadyShared = new Set(
        current.data.memberships.map((membership) => membership.userId)
      );
      const viewers: Viewer[] = parent.data.memberships.flatMap(
        (membership) => {
          const member = parent.data.users.find(
            (u) => u.id === membership.userId
          );
          return member &&
            member.role === UserRole.Viewer &&
            !membership.sourceId &&
            !alreadyShared.has(member.id)
            ? [
                {
                  id: member.id,
                  name: member.name,
                  permission: membership.permission,
                },
              ]
            : [];
        }
      );

      if (!viewers.length) {
        return;
      }

      setPrompted(document.id);
      dialogs.openModal({
        title: t("Share with external viewers?"),
        content: (
          <ShareWithViewersDialog
            document={document}
            viewers={viewers}
            onSubmit={dialogs.closeAllModals}
          />
        ),
      });
    };

    check().catch((err) => Logger.error("Failed to check viewers", err));

    return () => {
      cancelled = true;
    };
  }, [
    can.manageUsers,
    dialogs,
    document,
    isAuthor,
    parentDocumentId,
    publishedAt,
    t,
  ]);

  return null;
}

const ShareWithViewersDialog = observer(function ShareWithViewersDialog({
  document,
  viewers,
  onSubmit,
}: {
  document: Document;
  viewers: Viewer[];
  onSubmit: () => void;
}) {
  const { t } = useTranslation();
  const { userMemberships, documents } = useStores();
  const parent = document.parentDocumentId
    ? documents.get(document.parentDocumentId)
    : undefined;

  const handleSubmit = async () => {
    await Promise.all(
      viewers.map((viewer) =>
        userMemberships.create({
          documentId: document.id,
          userId: viewer.id,
          permission: viewer.permission,
        })
      )
    );
    toast.success(t("Shared with external viewers"));
    onSubmit();
  };

  return (
    <ConfirmationDialog
      onSubmit={handleSubmit}
      submitText={t("Share")}
      savingText={`${t("Sharing")}…`}
    >
      {t(
        "The parent document “{{ parentTitle }}” is shared with external viewers: {{ names }}. Do you want to share this document with them too? If you close this dialog it stays internal.",
        {
          parentTitle: parent?.displayTitle ?? t("Untitled"),
          names: viewers.map((viewer) => viewer.name).join(", "),
        }
      )}
    </ConfirmationDialog>
  );
});

/**
 * Whether the prompt was already shown for the document in this browser.
 *
 * @param documentId The document to check.
 * @returns True if the prompt was shown before.
 */
function hasPrompted(documentId: string) {
  try {
    return !!localStorage.getItem(`viewer-share-prompt:${documentId}`);
  } catch {
    return false;
  }
}

/**
 * Remember that the prompt was shown for the document in this browser.
 *
 * @param documentId The document to remember.
 */
function setPrompted(documentId: string) {
  try {
    localStorage.setItem(`viewer-share-prompt:${documentId}`, "1");
  } catch {
    // Storage may be unavailable, the prompt can then show again.
  }
}

export default observer(ShareWithViewersPrompt);
