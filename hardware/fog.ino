// Fog via power-switch: button held mechanically, D8 powers the RF remote.
// Heartbeat protocol (driven by hue_stream.py from DMX channel 19):
//   '1' -> fog ON, auto-off if not refreshed within 1500 ms
//   '0' -> fog OFF immediately
// The heartbeat makes this fail-safe: if the bridge dies mid-show,
// fog stops by itself instead of running forever.
const int POWER = 8;
const unsigned long TIMEOUT_MS = 1500;
unsigned long deadline = 0;

void setup() {
  pinMode(POWER, OUTPUT);
  digitalWrite(POWER, LOW);   // remote off at boot
  Serial.begin(9600);
  Serial.println("fog-ready");
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '1') {
      digitalWrite(POWER, HIGH);          // power remote -> transmits -> fog
      deadline = millis() + TIMEOUT_MS;   // refresh watchdog
    } else if (c == '0') {
      digitalWrite(POWER, LOW);
      deadline = 0;
    }
  }
  if (deadline != 0 && millis() > deadline) {   // heartbeat lost -> fail safe
    digitalWrite(POWER, LOW);
    deadline = 0;
  }
}
