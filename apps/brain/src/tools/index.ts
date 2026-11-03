import type { App } from '../app.ts';
import { locationTool, remindersTool } from './phone.ts';
import { proposalTools, registerServerActions } from './proposals.ts';
import {
  conversationReadTool,
  conversationSearchTool,
  skillLoadTool,
} from './misc.ts';
import { shellTool } from './shell.ts';
import { weatherTool } from './weather.ts';
import { webFetchTool } from './web.ts';

/** Native tools. Memory/inbox/jobs/... tools come from the ops registry (ToolRegistry.opTools). */
export function registerNativeTools(app: App): void {
  for (const t of [
    weatherTool,
    locationTool,
    remindersTool,
    shellTool,
    webFetchTool,
    conversationSearchTool,
    conversationReadTool,
    skillLoadTool,
    ...proposalTools,
  ]) {
    app.tools.register(t);
  }
  registerServerActions(app);
}
