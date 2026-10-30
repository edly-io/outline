import { UserRole } from "@shared/types";
import env from "@server/env";
import { User } from "@server/models";
import { buildUser } from "@server/test/factories";
import DemoteExternalMembersTask from "./DemoteExternalMembersTask";

const props = {
  limit: 100,
  partition: { partitionIndex: 0, partitionCount: 1 },
};

describe("DemoteExternalMembersTask", () => {
  afterEach(() => {
    env.INTERNAL_EMAIL_DOMAINS = undefined;
    vi.restoreAllMocks();
  });

  it("should demote external members to viewers", async () => {
    const external = await buildUser({ email: "someone@acme.test" });
    const internal = await buildUser({ email: "staff@example.com" });
    env.INTERNAL_EMAIL_DOMAINS = ["example.com"];
    // The test database is shared, so only return the users from this test.
    vi.spyOn(User, "findAll").mockResolvedValueOnce([external, internal]);

    await new DemoteExternalMembersTask().perform(props);

    await external.reload();
    await internal.reload();
    expect(external.role).toEqual(UserRole.Viewer);
    expect(internal.role).toEqual(UserRole.Member);
  });

  it("should do nothing when no internal domains are set", async () => {
    const external = await buildUser({ email: "someone@acme.test" });

    await new DemoteExternalMembersTask().perform(props);

    await external.reload();
    expect(external.role).toEqual(UserRole.Member);
  });
});
