class_name Voice
extends RefCounted

## Nori's lines. Grouped by the thing that happened to her, not by the button
## you pressed - she reacts to the *result* of your moderation.

const LINES := {
	"start": [
		"okay... stream is live. you've got chat, I've got the game <3",
		"hi everyone! mods are here so we're safe, right?",
		"deep breath. coziest stream of the week. let's go.",
	],
	"ban": [
		"thanks, mod! chat was getting wild.",
		"whoa, straight to the ban. I felt safer just now.",
		"okay that one REALLY needed it. thank you.",
		"chef's kiss. bye bye.",
	],
	"delete": [
		"clean. I didn't even have to read that one.",
		"good delete, I felt that one coming.",
		"thanks for the shield, mod.",
		"chat hygiene <3",
	],
	"allow_wholesome": [
		"aww, you guys are so sweet!",
		"stop, I'm going to get shy about this.",
		"ok that made my whole night.",
		"I'm keeping that one forever.",
	],
	"allow_friendly": [
		"hi! welcome in <3",
		"chat is so fun tonight.",
		"see, THIS is why I stream.",
		"we're just vibing, I love it.",
	],
	"abuse_allowed": [
		"ouch... did they really just say that?",
		"oh. um. never mind, let's keep playing!",
		"...I'm fine! we're fine!",
		"why is chat like this sometimes.",
	],
	"innocent_banned": [
		"wait, why did you ban them?",
		"they were being nice! that was MY friend-ish person!",
		"uh oh. that was a regular...",
		"mod... that one was innocent, right?",
	],
	"harmless_deleted": [
		"huh? that person was just saying hi!",
		"you can delete that?? it seemed fine?",
		"oh no, my joke got deleted...",
		"that one was actually sweet, you know.",
	],
	"too_harsh": [
		"was that ban-worthy? it seemed like a joke.",
		"maybe a delete would've been enough?",
		"ohhh, harsh mod today.",
	],
	"too_soft": [
		"um... do we have to just let that happen?",
		"I read that one twice. It wasn't nice.",
		"I'm gonna pretend I didn't see that.",
	],
	"serious_expired": [
		"...never mind. anyway! the game!",
		"that one really got to me, honestly.",
		"I'll just not read chat for a second.",
		"my smile slipped, did anyone see?",
	],
	"spam_expired": [
		"there's so much noise in chat right now...",
		"I can't find the nice messages anymore.",
		"spam spam spam... ugh.",
	],
	"combo": [
		"how did you know?!",
		"you're really looking out for me.",
		"my mod is a machine!!",
		"okay the chat is spotless right now.",
	],
	"high_trust": [
		"You're really looking out for me.",
		"I don't even check chat anymore, I just trust you.",
		"having you on mod is the best part of streaming.",
	],
	"near_win": [
		"I think today might be my favorite stream ever.",
		"this has been the best stream in a long time...",
		"can we... can we stay like this forever?",
	],
	"trust_gate": [
		"It's really nice tonight... but do you think we actually know each other yet?",
		"I'm having fun, but I still don't know how you call your decisions.",
		"Show me your judgment a little more and I'm yours. Metaphorically!",
	],
	"phase_growing": [
		"oh, we're getting more viewers!",
		"chat is filling up, stay with me?",
	],
	"phase_busy": [
		"okay it's getting fast in here!!",
		"so many messages, I love it and I'm scared.",
	],
	"phase_viral": [
		"someone clipped me?? we're going viral?!",
		"there are strangers here now. strangers!!",
	],
	"phase_final": [
		"last push! we can keep this place nice!",
		"deep breath, deep breath, we've got this.",
	],
	"win": [
		"best. stream. ever. thank you, mod <3",
		"I owe you something for this...",
	],
	"lose": [
		"um... I'm gonna end the stream here. sorry.",
		"I can't... I can't read chat right now.",
	],
}


static func line(rng: SplitMix32, key: String) -> String:
	var pool: Array = LINES.get(key, ["..."])
	return String(rng.pick(pool))
