// Fog via power-switch: button held mechanically, D8 powers the remote.
// atlas sends a number over serial = milliseconds of fog.
const int POWER = 8;
void setup() {
  pinMode(POWER, OUTPUT);
  digitalWrite(POWER, LOW);   // remote off at boot
  Serial.begin(9600);
  Serial.println("fog-ready");
}
void loop() {
  if (Serial.available()) {
    long ms = Serial.parseInt();
    if (ms > 0) {
      if (ms > 10000) ms = 10000;   // safety cap 10s
      digitalWrite(POWER, HIGH);    // power remote -> transmits (button held) -> fog
      delay(ms);
      digitalWrite(POWER, LOW);     // off
      Serial.print("FOG "); Serial.print(ms); Serial.println("ms OK");
    }
  }
}
