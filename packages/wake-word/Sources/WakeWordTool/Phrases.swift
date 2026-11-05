/// What the synthetic voices say. Positives are cropped to the first ~1.3 s, so the clip is the
/// wake phrase and not the command after it.
enum Phrases {
    static let wake = [
        "Hey Lotti", "Hey Lotti!", "Hey Lottie", "Hey Lotty", "Hi Lotti", "Hallo Lotti", "Hey, Lotti", "Hei Lotti",
    ]

    static let withCommand = [
        "Hey Lotti, wie wird das Wetter", "Hey Lotti, what's the weather", "Hey Lotti, wie spät ist es",
        "Hi Lotti, set a timer for ten minutes", "Hey Lotti, was steht heute an", "Hey Lotti, remind me to call mom",
    ]

    /// Sounds close to the wake phrase and must not trigger it.
    static let nearMisses = [
        "a lotta", "Lotte", "Hey Lola", "Hotel", "Lotto", "Hey Otto", "Hey Lotta", "Hey Lotte", "Hallo Lotte",
        "Hey Lisa", "Hey Siri", "Hey Google", "Hey Loki", "Hey Lena", "Hey Jan", "Lollipop", "What a lot", "Hey Bobby",
        "Hey Lorry", "Hallo Lotto", "Hotti Lotti", "Lottery",
    ]

    /// Everyday speech, English and German.
    static let speech = [
        "Wie wird das Wetter morgen", "I'm going to the store later", "What time is it", "Can you pass the salt",
        "Das ist ein langer Satz über nichts Besonderes", "Let's meet at the station at six", "Hast du heute Abend Zeit",
        "The meeting starts in five minutes", "Ich glaube, es regnet bald", "Please turn on the light",
        "Where did you put my keys", "Wir müssen noch einkaufen gehen", "That sounds like a great idea",
        "Kannst du mir bitte helfen", "I think we should leave now", "Das Essen ist gleich fertig",
        "Did you see the news this morning", "Morgen fahren wir an den See", "Remind me to call the dentist",
        "Stell bitte einen Timer", "How was your day", "Ich habe das nicht verstanden", "Okay, sounds good",
        "Hey, how are you doing", "Hallo, schön dich zu sehen", "Hi there, nice to meet you", "Hey Jan, wie geht's",
        "Es gibt so viele Dinge zu tun", "There is a lot to do today", "Open the door please",
    ]
}
