/*
Arduino snippet for TLasSerial.
Flash this app to an Arduino or a similar device to try if the serial communication works.
*/

#if defined(ARDUINO_ARCH_ESP32)
#define LED_BUILTIN 15
#endif
# define False  false;
# define True  true;
int Pause = 1000;
bool LedState = HIGH;
bool AlwaysON = false;
bool AlwaysOFF = false;

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);

  Serial.begin(9600);
  while (!Serial) {;}
  Serial.write("Hi!\nUse: fast; normal; slow; on or off.\n");
}

// the loop function runs over and over again forever
void loop() {
  if (AlwaysON)  {digitalWrite(LED_BUILTIN,HIGH);} else
  if (AlwaysOFF) {digitalWrite(LED_BUILTIN,LOW);} else
  {
  digitalWrite(LED_BUILTIN, LedState);  // turn the LED on (HIGH is the voltage level)
  delay(Pause);                      // wait for a second
  LedState = ! LedState;}
  
  if (Serial.available() > 0) {
   String inSerial = Serial.readString();
   inSerial.toLowerCase();
   if (inSerial.startsWith("on"))     {AlwaysON = True;  AlwaysOFF = False; Serial.write("Let it be light!\n");} else
   if (inSerial.startsWith("off"))    {AlwaysON = False; AlwaysOFF = True; Serial.write("Darkness.\n");} else
   if (inSerial.startsWith("fast"))   {AlwaysON = False;  AlwaysOFF = False; Pause = 100;     Serial.write("Blinking fast...\n");} else
   if (inSerial.startsWith("normal")) {AlwaysON = False;  AlwaysOFF = False; Pause = 1000;  Serial.write("Blinking normally...\n");} else
   if (inSerial.startsWith("slow"))   {AlwaysON = False;  AlwaysOFF = False; Pause = 3000;    Serial.write("Blinking sloooowlyyyyy...\n");} else
   if (inSerial.startsWith("help"))   {Serial.write("In case of an emergency call 112!\n Otherwise use: fast; normal; slow; on or off.\n");} else
   {Serial.write("I am not sure that I understand you.\n");}
  }
}

