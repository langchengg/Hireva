#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

#include "sherpa-onnx/c-api/c-api.h"

namespace {

constexpr int32_t kTargetSampleRate = 16000;
constexpr char kSource[] = "local_parakeet_asr";
constexpr char kRuntimeVersion[] = "1";
constexpr char kOnnxRuntimeVersion[] = "1.27.0";

struct Options {
  bool health = false;
  bool probeModel = false;
  bool jsonl = false;
  std::string modelDirectory;
  std::string sessionID = "sidecar";
  std::string captureMode = "systemAudioOnly";
  std::string wavPath;
  int32_t numThreads = 2;
  float silenceThreshold = 0.0035F;
  float trailingSilenceSeconds = 0.85F;
  float minimumUtteranceSeconds = 0.35F;
  float maximumUtteranceSeconds = 14.0F;
};

using Recognizer = std::unique_ptr<const SherpaOnnxOfflineRecognizer,
                                   decltype(&SherpaOnnxDestroyOfflineRecognizer)>;

[[noreturn]] void Fail(const std::string &message);

class ModelUseLock {
 public:
  explicit ModelUseLock(const std::string &modelDirectory) {
    NSString *modelPath = [NSString stringWithUTF8String:modelDirectory.c_str()];
    NSString *modelIDDirectory = [modelPath stringByDeletingLastPathComponent];
    NSString *namespaceDirectory = [modelIDDirectory stringByDeletingLastPathComponent];
    NSString *modelID = [modelIDDirectory lastPathComponent];
    NSString *lockName = [NSString stringWithFormat:@".%@.use.lock", modelID];
    NSString *lockPath = [namespaceDirectory stringByAppendingPathComponent:lockName];
    descriptor_ = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (descriptor_ < 0 || flock(descriptor_, LOCK_SH) != 0) {
      if (descriptor_ >= 0) {
        close(descriptor_);
        descriptor_ = -1;
      }
      Fail("Could not acquire the Parakeet model-use lock");
    }
  }

  ModelUseLock(const ModelUseLock &) = delete;
  ModelUseLock &operator=(const ModelUseLock &) = delete;

  ~ModelUseLock() {
    if (descriptor_ >= 0) {
      flock(descriptor_, LOCK_UN);
      close(descriptor_);
    }
  }

 private:
  int descriptor_ = -1;
};

void WriteJSON(NSDictionary *object, FILE *stream = stdout) {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
  if (data == nil) {
    std::fprintf(stderr, "failed to encode JSON: %s\n",
                 error.localizedDescription.UTF8String);
    return;
  }
  std::fwrite(data.bytes, 1, data.length, stream);
  std::fputc('\n', stream);
  std::fflush(stream);
}

[[noreturn]] void Fail(const std::string &message) {
  WriteJSON(@{
    @"type" : @"error",
    @"message" : [NSString stringWithUTF8String:message.c_str()]
  });
  std::fprintf(stderr, "fatal: %s\n", message.c_str());
  std::exit(1);
}

std::string RequiredArgument(int argc, char **argv, int *index,
                             const std::string &flag) {
  if (*index + 1 >= argc) {
    Fail("Missing value for " + flag);
  }
  *index += 1;
  return argv[*index];
}

float FloatArgument(int argc, char **argv, int *index,
                    const std::string &flag) {
  const auto value = RequiredArgument(argc, argv, index, flag);
  char *end = nullptr;
  const float parsed = std::strtof(value.c_str(), &end);
  if (end == nullptr || *end != '\0') {
    Fail("Invalid numeric value for " + flag);
  }
  return parsed;
}

Options ParseOptions(int argc, char **argv) {
  Options options;
  for (int index = 1; index < argc; ++index) {
    const std::string argument = argv[index];
    if (argument == "--health") {
      options.health = true;
    } else if (argument == "--probe-model") {
      options.probeModel = true;
    } else if (argument == "--jsonl") {
      options.jsonl = true;
    } else if (argument == "--model-dir") {
      options.modelDirectory = RequiredArgument(argc, argv, &index, argument);
    } else if (argument == "--session-id") {
      options.sessionID = RequiredArgument(argc, argv, &index, argument);
    } else if (argument == "--capture-mode") {
      options.captureMode = RequiredArgument(argc, argv, &index, argument);
    } else if (argument == "--wav") {
      options.wavPath = RequiredArgument(argc, argv, &index, argument);
    } else if (argument == "--num-threads") {
      options.numThreads = static_cast<int32_t>(
          FloatArgument(argc, argv, &index, argument));
    } else if (argument == "--silence-threshold") {
      options.silenceThreshold = FloatArgument(argc, argv, &index, argument);
    } else if (argument == "--trailing-silence-seconds") {
      options.trailingSilenceSeconds =
          FloatArgument(argc, argv, &index, argument);
    } else if (argument == "--min-utterance-seconds") {
      options.minimumUtteranceSeconds =
          FloatArgument(argc, argv, &index, argument);
    } else if (argument == "--max-utterance-seconds") {
      options.maximumUtteranceSeconds =
          FloatArgument(argc, argv, &index, argument);
    } else {
      Fail("Unsupported argument: " + argument);
    }
  }
  return options;
}

bool IsRegularReadableFile(const std::string &path) {
  NSString *string = [NSString stringWithUTF8String:path.c_str()];
  NSDictionary<NSFileAttributeKey, id> *attributes =
      [[NSFileManager defaultManager] attributesOfItemAtPath:string error:nil];
  return [attributes[NSFileType] isEqual:NSFileTypeRegular] &&
         [[NSFileManager defaultManager] isReadableFileAtPath:string];
}

Recognizer CreateRecognizer(const Options &options) {
  if (options.modelDirectory.empty()) {
    Fail("--model-dir is required");
  }

  const std::string encoder = options.modelDirectory + "/encoder.int8.onnx";
  const std::string decoder = options.modelDirectory + "/decoder.int8.onnx";
  const std::string joiner = options.modelDirectory + "/joiner.int8.onnx";
  const std::string tokens = options.modelDirectory + "/tokens.txt";
  for (const auto &path : {encoder, decoder, joiner, tokens}) {
    if (!IsRegularReadableFile(path)) {
      Fail("Missing or unreadable model file: " + path);
    }
  }

  SherpaOnnxOfflineRecognizerConfig config;
  std::memset(&config, 0, sizeof(config));
  config.feat_config.sample_rate = kTargetSampleRate;
  config.feat_config.feature_dim = 80;
  config.model_config.transducer.encoder = encoder.c_str();
  config.model_config.transducer.decoder = decoder.c_str();
  config.model_config.transducer.joiner = joiner.c_str();
  config.model_config.tokens = tokens.c_str();
  config.model_config.num_threads = std::max<int32_t>(1, options.numThreads);
  config.model_config.provider = "cpu";
  config.model_config.model_type = "nemo_transducer";
  config.decoding_method = "greedy_search";

  const SherpaOnnxOfflineRecognizer *recognizer =
      SherpaOnnxCreateOfflineRecognizer(&config);
  if (recognizer == nullptr) {
    Fail("Failed to create the Parakeet recognizer");
  }
  return Recognizer(recognizer, &SherpaOnnxDestroyOfflineRecognizer);
}

std::vector<float> Resample(const float *samples, size_t count,
                            int32_t sourceRate) {
  if (samples == nullptr || count == 0 || sourceRate <= 0) {
    return {};
  }
  if (sourceRate == kTargetSampleRate) {
    return std::vector<float>(samples, samples + count);
  }

  const double ratio = static_cast<double>(kTargetSampleRate) / sourceRate;
  const size_t targetCount =
      std::max<size_t>(1, static_cast<size_t>(std::llround(count * ratio)));
  std::vector<float> output(targetCount);
  for (size_t index = 0; index < targetCount; ++index) {
    const double sourcePosition = static_cast<double>(index) / ratio;
    const size_t lower = std::min(static_cast<size_t>(sourcePosition), count - 1);
    const size_t upper = std::min(lower + 1, count - 1);
    const float fraction = static_cast<float>(sourcePosition - lower);
    output[index] = samples[lower] + (samples[upper] - samples[lower]) * fraction;
  }
  return output;
}

std::string Decode(const SherpaOnnxOfflineRecognizer *recognizer,
                   const std::vector<float> &samples) {
  const SherpaOnnxOfflineStream *stream =
      SherpaOnnxCreateOfflineStream(recognizer);
  if (stream == nullptr) {
    Fail("Failed to create an offline recognition stream");
  }
  SherpaOnnxAcceptWaveformOffline(stream, kTargetSampleRate, samples.data(),
                                  static_cast<int32_t>(samples.size()));
  SherpaOnnxDecodeOfflineStream(recognizer, stream);
  const SherpaOnnxOfflineRecognizerResult *result =
      SherpaOnnxGetOfflineStreamResult(stream);
  std::string text;
  if (result != nullptr && result->text != nullptr) {
    text = result->text;
  }
  if (result != nullptr) {
    SherpaOnnxDestroyOfflineRecognizerResult(result);
  }
  SherpaOnnxDestroyOfflineStream(stream);
  return text;
}

NSString *SpeakerForAudioSource(NSString *audioSource) {
  return [audioSource isEqualToString:@"microphone"] ? @"candidate"
                                                        : @"interviewer";
}

class UtteranceDecoder {
 public:
  UtteranceDecoder(const SherpaOnnxOfflineRecognizer *recognizer,
                   const Options &options, std::string audioSource)
      : recognizer_(recognizer),
        silenceThreshold_(options.silenceThreshold),
        trailingSilenceSeconds_(options.trailingSilenceSeconds),
        minimumUtteranceSeconds_(options.minimumUtteranceSeconds),
        maximumUtteranceSeconds_(options.maximumUtteranceSeconds),
        audioSource_(std::move(audioSource)) {}

  void Accept(const float *samples, size_t count, int32_t sourceRate) {
    std::vector<float> resampled = Resample(samples, count, sourceRate);
    if (resampled.empty()) {
      return;
    }
    const float duration =
        static_cast<float>(resampled.size()) / kTargetSampleRate;
    double energy = 0;
    for (float sample : resampled) {
      energy += static_cast<double>(sample) * sample;
    }
    const float rms =
        static_cast<float>(std::sqrt(energy / resampled.size()));
    const bool speechLike = rms >= silenceThreshold_;

    if (speechLike && samples_.empty()) {
      segmentStart_ = audioClock_;
      silenceSeconds_ = 0;
    }
    if (!samples_.empty() || speechLike) {
      samples_.insert(samples_.end(), resampled.begin(), resampled.end());
      silenceSeconds_ = speechLike ? 0 : silenceSeconds_ + duration;
    }
    audioClock_ += duration;

    const float activeDuration =
        static_cast<float>(samples_.size()) / kTargetSampleRate;
    if (!samples_.empty() &&
        ((silenceSeconds_ >= trailingSilenceSeconds_ &&
          activeDuration >= minimumUtteranceSeconds_) ||
         activeDuration >= maximumUtteranceSeconds_)) {
      Flush();
    }
  }

  void Flush() {
    if (samples_.empty()) {
      return;
    }
    const float duration =
        static_cast<float>(samples_.size()) / kTargetSampleRate;
    if (duration >= minimumUtteranceSeconds_) {
      const std::string text = Decode(recognizer_, samples_);
      NSString *trimmed = [[NSString stringWithUTF8String:text.c_str()]
          stringByTrimmingCharactersInSet:
              NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (trimmed.length > 0) {
        NSString *audioSource =
            [NSString stringWithUTF8String:audioSource_.c_str()];
        WriteJSON(@{
          @"segmentId" : NSUUID.UUID.UUIDString,
          @"text" : trimmed,
          @"isFinal" : @YES,
          @"startTime" : @(segmentStart_),
          @"endTime" : @(segmentStart_ + duration),
          @"confidence" : NSNull.null,
          @"source" : [NSString stringWithUTF8String:kSource],
          @"audioSource" : audioSource,
          @"speaker" : SpeakerForAudioSource(audioSource)
        });
      }
    }
    samples_.clear();
    silenceSeconds_ = 0;
  }

 private:
  const SherpaOnnxOfflineRecognizer *recognizer_;
  float silenceThreshold_;
  float trailingSilenceSeconds_;
  float minimumUtteranceSeconds_;
  float maximumUtteranceSeconds_;
  std::string audioSource_;
  float audioClock_ = 0;
  float segmentStart_ = 0;
  float silenceSeconds_ = 0;
  std::vector<float> samples_;
};

NSDictionary *ParseJSONLine(const std::string &line) {
  NSData *data = [NSData dataWithBytes:line.data() length:line.size()];
  NSError *error = nil;
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (![object isKindOfClass:NSDictionary.class]) {
    const char *message = error.localizedDescription.UTF8String;
    Fail(std::string("Invalid JSONL input: ") + (message ?: "not an object"));
  }
  return static_cast<NSDictionary *>(object);
}

std::string DefaultAudioSource(const Options &options) {
  return options.captureMode == "microphoneOnly" ? "microphone" : "systemAudio";
}

int RunJSONL(const Options &options,
             const SherpaOnnxOfflineRecognizer *recognizer) {
  std::unordered_map<std::string, std::unique_ptr<UtteranceDecoder>> decoders;
  auto decoderFor = [&](const std::string &audioSource) -> UtteranceDecoder * {
    auto found = decoders.find(audioSource);
    if (found != decoders.end()) {
      return found->second.get();
    }
    auto decoder =
        std::make_unique<UtteranceDecoder>(recognizer, options, audioSource);
    UtteranceDecoder *pointer = decoder.get();
    decoders.emplace(audioSource, std::move(decoder));
    return pointer;
  };

  std::fprintf(stderr, "native Parakeet ready session=%s capture_mode=%s\n",
               options.sessionID.c_str(), options.captureMode.c_str());
  std::string line;
  while (std::getline(std::cin, line)) {
    if (line.empty()) {
      continue;
    }
    @autoreleasepool {
      NSDictionary *event = ParseJSONLine(line);
      NSString *type = event[@"type"];
      if ([type isEqualToString:@"audio"]) {
        if (![event[@"encoding"] isEqual:@"float32le"] ||
            ![event[@"audio"] isKindOfClass:NSString.class]) {
          Fail("Unsupported or missing audio encoding");
        }
        const int32_t sampleRate = [event[@"sampleRate"] intValue];
        const int32_t channels = std::max(1, [event[@"channels"] intValue]);
        NSData *audio = [[NSData alloc]
            initWithBase64EncodedString:event[@"audio"]
                                 options:0];
        if (audio == nil || audio.length % sizeof(float) != 0) {
          Fail("Invalid float32 audio payload");
        }
        const size_t interleavedCount = audio.length / sizeof(float);
        const float *interleaved = static_cast<const float *>(audio.bytes);
        std::vector<float> mono;
        if (channels == 1) {
          mono.assign(interleaved, interleaved + interleavedCount);
        } else {
          if (interleavedCount % static_cast<size_t>(channels) != 0) {
            Fail("Audio frame count is not divisible by channel count");
          }
          mono.resize(interleavedCount / channels);
          for (size_t frame = 0; frame < mono.size(); ++frame) {
            float sum = 0;
            for (int32_t channel = 0; channel < channels; ++channel) {
              sum += interleaved[frame * channels + channel];
            }
            mono[frame] = sum / channels;
          }
        }
        NSString *sourceValue = [event[@"audioSource"]
            isKindOfClass:NSString.class]
            ? event[@"audioSource"]
            : [NSString stringWithUTF8String:DefaultAudioSource(options).c_str()];
        if (![sourceValue isEqualToString:@"microphone"] &&
            ![sourceValue isEqualToString:@"systemAudio"]) {
          Fail("Unsupported audioSource");
        }
        decoderFor(sourceValue.UTF8String)
            ->Accept(mono.data(), mono.size(), sampleRate);
      } else if ([type isEqualToString:@"flush"]) {
        for (auto &entry : decoders) {
          entry.second->Flush();
        }
      } else if ([type isEqualToString:@"stop"]) {
        for (auto &entry : decoders) {
          entry.second->Flush();
        }
        return 0;
      } else {
        Fail("Unsupported JSONL event type");
      }
    }
  }
  for (auto &entry : decoders) {
    entry.second->Flush();
  }
  return 0;
}

int DecodeWave(const Options &options,
               const SherpaOnnxOfflineRecognizer *recognizer) {
  const SherpaOnnxWave *wave = SherpaOnnxReadWave(options.wavPath.c_str());
  if (wave == nullptr) {
    Fail("Failed to read WAV file");
  }
  const auto samples =
      Resample(wave->samples, wave->num_samples, wave->sample_rate);
  const std::string text = Decode(recognizer, samples);
  const double duration =
      static_cast<double>(samples.size()) / kTargetSampleRate;
  SherpaOnnxFreeWave(wave);
  WriteJSON(@{
    @"segmentId" : @"wav-test",
    @"text" : [NSString stringWithUTF8String:text.c_str()],
    @"isFinal" : @YES,
    @"startTime" : @0,
    @"endTime" : @(duration),
    @"confidence" : NSNull.null,
    @"source" : [NSString stringWithUTF8String:kSource],
    @"audioSource" : @"systemAudio",
    @"speaker" : @"interviewer"
  });
  return 0;
}

NSDictionary *HealthPayload(NSString *status, NSString *modelStatus) {
#if defined(__aarch64__) || defined(__arm64__)
  NSString *architecture = @"arm64";
#elif defined(__x86_64__)
  NSString *architecture = @"x86_64";
#else
  NSString *architecture = @"unknown";
#endif
  return @{
    @"status" : status,
    @"runtimeMode" : @"bundled_native",
    @"runtimeVersion" : [NSString stringWithUTF8String:kRuntimeVersion],
    @"sherpaVersion" :
        [NSString stringWithUTF8String:SherpaOnnxGetVersionStr()],
    @"onnxRuntimeVersion" :
        [NSString stringWithUTF8String:kOnnxRuntimeVersion],
    @"architecture" : architecture,
    @"source" : [NSString stringWithUTF8String:kSource],
    @"modelStatus" : modelStatus
  };
}

}  // namespace

int main(int argc, char **argv) {
  @autoreleasepool {
    const Options options = ParseOptions(argc, argv);
    if (options.health && !options.probeModel) {
      WriteJSON(HealthPayload(@"ok", @"not_probed"));
      return 0;
    }
    ModelUseLock modelUseLock(options.modelDirectory);
    Recognizer recognizer = CreateRecognizer(options);
    if (options.probeModel) {
      WriteJSON(HealthPayload(@"ok", @"ready"));
      return 0;
    }
    if (!options.wavPath.empty()) {
      return DecodeWave(options, recognizer.get());
    }
    if (!options.jsonl) {
      Fail("--jsonl, --wav, --probe-model, or --health is required");
    }
    return RunJSONL(options, recognizer.get());
  }
}
