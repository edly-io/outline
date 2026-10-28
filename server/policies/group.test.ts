import { GroupPermission } from "@shared/types";
import { Group, GroupUser } from "@server/models";
import {
  buildAdmin,
  buildGroup,
  buildGuestUser,
  buildTeam,
  buildUser,
  buildViewer,
} from "@server/test/factories";
import { serialize } from "./index";

const loadGroup = (id: string, userId: string) =>
  Group.findByPk(id, {
    include: [
      {
        model: GroupUser,
        as: "groupUsers",
        required: false,
        where: { userId },
      },
    ],
  });

describe("policies/group", () => {
  it("should allow a group admin to update", async () => {
    const team = await buildTeam();
    const admin = await buildAdmin({ teamId: team.id });
    const user = await buildUser({ teamId: team.id });
    const group = await buildGroup({ teamId: team.id });
    await GroupUser.create({
      groupId: group.id,
      userId: user.id,
      createdById: admin.id,
      permission: GroupPermission.Admin,
    });
    const reloaded = await loadGroup(group.id, user.id);
    expect(serialize(user, reloaded).update).toBeTruthy();
  });

  it("should not allow a group admin from another team to update", async () => {
    const user = await buildUser();
    const group = await buildGroup();
    await GroupUser.create({
      groupId: group.id,
      userId: user.id,
      createdById: user.id,
      permission: GroupPermission.Admin,
    });
    const reloaded = await loadGroup(group.id, user.id);
    expect(serialize(user, reloaded).update).toEqual(false);
  });

  it("should allow members to list and read groups", async () => {
    const team = await buildTeam();
    const user = await buildUser({ teamId: team.id });
    const group = await buildGroup({ teamId: team.id });
    const reloaded = await loadGroup(group.id, user.id);
    expect(serialize(user, team).listGroups).toBeTruthy();
    expect(serialize(user, reloaded).read).toBeTruthy();
  });

  it("should not allow viewers to list or read groups", async () => {
    const team = await buildTeam();
    const viewer = await buildViewer({ teamId: team.id });
    const group = await buildGroup({ teamId: team.id });
    const reloaded = await loadGroup(group.id, viewer.id);
    expect(serialize(viewer, team).listGroups).toEqual(false);
    expect(serialize(viewer, reloaded).read).toEqual(false);
  });

  it("should not allow guests to list or read groups", async () => {
    const team = await buildTeam();
    const guest = await buildGuestUser({ teamId: team.id });
    const group = await buildGroup({ teamId: team.id });
    const reloaded = await loadGroup(group.id, guest.id);
    expect(serialize(guest, team).listGroups).toEqual(false);
    expect(serialize(guest, reloaded).read).toEqual(false);
  });
});
