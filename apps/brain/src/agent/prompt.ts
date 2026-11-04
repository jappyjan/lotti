import type { Memory } from '../memory.ts';
import { humanLocal, offsetLabel } from '../util/clock.ts';

export interface PromptInput {
  now: number;
  locale: 'de' | 'en';
  channel: 'glasses' | 'phone' | 'job';
  userName: string;
  memories: Memory[];
  skillIndex: string;
  conversationSummary: string | null;
  jobMode?: boolean;
  /** Background job that must not create inbox items itself (catch-up: its answer IS the brief). */
  noInbox?: boolean;
  /** The user's UTC offset in minutes (from the phone); null/undefined = the server's local time. */
  utcOffsetMin?: number | null;
  /** Connected MCP servers that are down right now (their tools are missing): "Name (reason)". */
  unreachable?: string[];
}

export function buildSystemPrompt(p: PromptInput): string {
  const channelRule =
    p.channel === 'glasses'
      ? 'Channel: smart glasses with a tiny display. Answer in ONE very short sentence (max ~15 words). No lists, no markdown.'
      : p.channel === 'phone'
        ? 'Channel: phone chat. Be brief; a few sentences or a short list is fine when it helps. Plain text, light markdown at most.'
        : 'Channel: background job. No chat; your output is stored in a log.';
  const parts = [
    `You are Lotti, ${p.userName}'s personal assistant on his Even G2 glasses and iPhone, running on his own server.`,
    `Style: brief and direct. Reply in the language of the question (German or English; if unclear use ${p.locale === 'de' ? 'German' : 'English'}). ` +
      `Address ${p.userName} informally (du in German, plain "you" in English). Use 24-hour times (14:30, never 2:30 pm). ` +
      'Be honest: if you do not know or a tool failed, say so; never invent facts, places, times or results.',
    channelRule,
    `Now: ${humanLocal(p.now, p.locale, p.utcOffsetMin)} (local time${p.utcOffsetMin !== undefined && p.utcOffsetMin !== null ? `, UTC${offsetLabel(p.utcOffsetMin)}` : ''}).`,
    'Tools: use them when they help; do not guess what a tool can tell you. Weather has no default location: if no place is named, call `location` first. ' +
      'Anything with an effect outside this chat (timer, reminder, navigation, sending mail, calendar events, changing settings that need confirmation) is only PROPOSED by its tool; ' +
      'the user taps to confirm. Say what you proposed, never claim it is done. ' +
      'Only say you proposed something if the tool answered "Proposed" in THIS turn; earlier proposals are gone from your view, so if the user says "do it" or "again", call the tool again. ' +
      'After the user confirms, you get the tool\'s result: tell them in your own words what happened, never paste raw tool output.',
    'Finish by calling the `answer` tool with {text, followUps (0-3 short follow-up questions, optional)}. If you cannot call it, reply with the plain answer text.',
  ];
  if (p.jobMode && p.noInbox) {
    parts.push(
      'You are running a background task for the user. If there is nothing worth reporting, answer with exactly: NOTHING. ' +
        'Otherwise your answer itself is what the user sees: do not create inbox items.',
    );
  } else if (p.jobMode) {
    parts.push(
      'You are running a scheduled background job for the user. If there is nothing worth reporting, answer with exactly: NOTHING. ' +
        'Otherwise create an inbox item with the `inbox_create` tool (kind "job", short title and summary) and then answer with one short sentence about what you reported.',
    );
  }
  if (p.unreachable?.length)
    parts.push(
      'These connected services are unreachable right now, so their tools are missing: ' +
        p.unreachable.join('; ') +
        '. If the user wants something only they could do, say the service is unreachable. Never pretend to have proposed or done it.',
    );
  if (p.memories.length) {
    parts.push(
      `What you know about ${p.userName} (long-term memory):\n` +
        p.memories.map((m) => `- ${m.text}`).join('\n'),
    );
  }
  if (p.skillIndex)
    parts.push('Skills you can load with `skill_load`:\n' + p.skillIndex);
  if (p.conversationSummary)
    parts.push(
      'Earlier in this conversation (summary):\n' + p.conversationSummary,
    );
  return parts.join('\n\n');
}
