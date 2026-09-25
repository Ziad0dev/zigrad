// A tiny corpus of names, each ending in '.' (the end-of-name token).
const corpus = "emma.olivia.ava.isabella.sophia.charlotte.mia.amelia.harper.evelyn." ++
    "abigail.emily.elizabeth.mila.ella.avery.sofia.camila.aria.scarlett." ++
    "victoria.madison.luna.grace.chloe.penelope.layla.riley.zoey.nora." ++
    "lily.eleanor.hannah.lillian.addison.aubrey.ellie.stella.natalie.zoe." ++
    "leah.hazel.violet.aurora.savannah.audrey.brooklyn.bella.claire.skylar.";

const vocab = 27; // '.' and a-z

fn id(ch: u8) usize {
    return if (ch == '.') 0 else ch - 'a' + 1;
}
