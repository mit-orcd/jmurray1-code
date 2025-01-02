from pydub import AudioSegment
import speech_recognition as sr
import sys

#Stolen from Michel

# Step 1: Convert the audio file to WAV if not already in that format
def convert_to_wav(input_file, output_file):
    audio = AudioSegment.from_file(input_file)
    audio.export(output_file, format="wav")

# Step 2: Transcribe the WAV file
def transcribe_audio(wav_file):
    recognizer = sr.Recognizer()
    with sr.AudioFile(wav_file) as source:
        audio_data = recognizer.record(source)
        try:
            # Use Google Web Speech API for transcription
            return recognizer.recognize_google(audio_data, language='es-ES')
        except sr.UnknownValueError:
            return "Unable to understand the audio."
        except sr.RequestError as e:
            return f"Speech recognition error: {e}"

# Paths to your audio files
input_file = sys.argv[1]  # Replace with your input file path
output_file = "/Users/erbmi1/Downloads/converted_audio.wav"

# Convert and transcribe
convert_to_wav(input_file, output_file)
transcription = transcribe_audio(output_file)

print("Transcription:")
print(transcription)
