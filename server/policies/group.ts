import { Group, User, Team } from "@server/models";
import { allow } from "./cancan";
import {
  and,
  isTeamAdmin,
  isTeamModel,
  isTeamMutable,
  isGroupAdmin,
} from "./utils";

allow(User, "createGroup", Team, (actor, team) =>
  and(
    //
    isTeamAdmin(actor, team),
    isTeamMutable(actor)
  )
);

// Viewers cannot see groups, matching guests, so that external users do not
// learn the workspace's internal team structure.
allow(User, "listGroups", Team, (actor, team) =>
  and(
    //
    isTeamModel(actor, team),
    !actor.isGuest,
    !actor.isViewer
  )
);

allow(User, "read", Group, (actor, group) =>
  and(
    //
    isTeamModel(actor, group),
    !actor.isGuest,
    !actor.isViewer
  )
);

allow(User, "update", Group, (actor, group) =>
  and(
    //
    isGroupAdmin(actor, group),
    isTeamMutable(actor)
  )
);

allow(User, "delete", Group, (actor, group) =>
  and(
    //
    isTeamAdmin(actor, group),
    isTeamMutable(actor),
    !Array.isArray(group?.externalGroups) || group.externalGroups.length === 0
  )
);
