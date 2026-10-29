import { Op } from "sequelize";
import { UserRole } from "@shared/types";
import { Minute } from "@shared/utils/time";
import env from "@server/env";
import Logger from "@server/logging/Logger";
import { User } from "@server/models";
import { TaskPriority } from "./base/BaseTask";
import type { Props } from "./base/CronTask";
import { CronTask, TaskInterval } from "./base/CronTask";

/**
 * Demotes members with an email outside of `INTERNAL_EMAIL_DOMAINS` to viewers,
 * covering users that existed before the setting was configured.
 */
export default class DemoteExternalMembersTask extends CronTask {
  public async perform({ limit, partition }: Props) {
    if (!env.INTERNAL_EMAIL_DOMAINS?.length) {
      return;
    }

    const domains = env.INTERNAL_EMAIL_DOMAINS;
    const members = await User.findAll({
      where: {
        role: UserRole.Member,
        email: {
          [Op.and]: [
            { [Op.ne]: null },
            ...domains.map((domain) => ({ [Op.notILike]: `%@${domain}` })),
          ],
        },
        ...this.getPartitionWhereClause("id", partition),
      },
      limit,
    });

    for (const user of members.filter((member) => member.isExternal)) {
      Logger.info("task", `Demoting external member ${user.id} to viewer`);
      await user.update({ role: UserRole.Viewer });
    }
  }

  public get cron() {
    return {
      interval: TaskInterval.Hour,
      partitionWindow: 15 * Minute.ms,
    };
  }

  public get options() {
    return {
      attempts: 1,
      priority: TaskPriority.Background,
    };
  }
}
