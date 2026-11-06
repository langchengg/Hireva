#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <future>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <sys/file.h>
#include <thread>
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
  std::string decodingMethod = "greedy_search";
  std::string hotwordsFile;
  std::string bpeVocab;
  bool approximateBPEVocab = false;
  float hotwordsScore = 1.5F;
  int32_t numThreads = 2;
  float silenceThreshold = 0.0035F;
  float trailingSilenceSeconds = 0.85F;
  float minimumUtteranceSeconds = 0.35F;
  float maximumUtteranceSeconds = 14.0F;
};

using Recognizer = std::unique_ptr<const SherpaOnnxOfflineRecognizer,
                                   decltype(&SherpaOnnxDestroyOfflineRecognizer)>;
using Resampler = std::unique_ptr<const SherpaOnnxLinearResampler,
                                  decltype(&SherpaOnnxDestroyLinearResampler)>;

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
    } else if (argument == "--decoding-method") {
      options.decodingMethod = RequiredArgument(argc, argv, &index, argument);
    } else if (argument == "--hotwords-file") {
      options.hotwordsFile = RequiredArgument(argc, argv, &index, argument);
    } else if (argument == "--bpe-vocab") {
      options.bpeVocab = RequiredArgument(argc, argv, &index, argument);
    } else if (argument == "--approximate-bpe-vocab") {
      options.approximateBPEVocab = true;
    } else if (argument == "--hotwords-score") {
      options.hotwordsScore = FloatArgument(argc, argv, &index, argument);
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
  if (options.decodingMethod != "greedy_search" &&
      options.decodingMethod != "modified_beam_search") {
    Fail("Unsupported decoding method");
  }
  if (!std::isfinite(options.hotwordsScore) || options.hotwordsScore < 0 || options.hotwordsScore > 3) {
    Fail("Hotwords score must be finite and between 0 and 3");
  }
  if (!std::isfinite(options.silenceThreshold) || options.silenceThreshold < 0 ||
      !std::isfinite(options.trailingSilenceSeconds) || options.trailingSilenceSeconds <= 0 ||
      !std::isfinite(options.minimumUtteranceSeconds) || options.minimumUtteranceSeconds < 0 ||
      !std::isfinite(options.maximumUtteranceSeconds) || options.maximumUtteranceSeconds <= 0 ||
      options.maximumUtteranceSeconds < options.minimumUtteranceSeconds ||
      static_cast<double>(options.maximumUtteranceSeconds) * kTargetSampleRate > INT32_MAX) {
    Fail("Invalid audio segmentation limits");
  }
  if ((!options.hotwordsFile.empty() || !options.bpeVocab.empty() || options.approximateBPEVocab) &&
      (options.hotwordsFile.empty() || options.bpeVocab.empty() || options.decodingMethod != "modified_beam_search")) {
    Fail("Hotwords require modified_beam_search, --hotwords-file and --bpe-vocab");
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
  config.decoding_method = options.decodingMethod.c_str();
  config.max_active_paths = 4;
  if (!options.hotwordsFile.empty()) {
    if (!IsRegularReadableFile(options.hotwordsFile)) { Fail("Missing hotwords file"); }
    NSString *path = [NSString stringWithUTF8String:options.hotwordsFile.c_str()];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 '-"];
    if (data.length == 0 || data.length > 4096 || text == nil || lines.count > 33) {
      Fail("Invalid contextual vocabulary size or encoding");
    }
    for (NSString *line in lines) {
      if (line.length == 0) { continue; }
      if ([line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 64 ||
          ![line isEqualToString:[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]] ||
          [line containsString:@"  "] ||
          [line rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet].location == NSNotFound ||
          [line rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound ||
          [line componentsSeparatedByString:@" "].count > 4) {
        Fail("Invalid contextual term");
      }
    }
    if (options.approximateBPEVocab) {
      // ponytail: equal scores follow the pinned sherpa v2 example; replace with matched v3 tokenizer scores when available.
      NSData *tokenData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:tokens.c_str()]];
      NSString *tokenText = [[NSString alloc] initWithData:tokenData encoding:NSUTF8StringEncoding];
      if (tokenText == nil || tokenData.length == 0 || tokenData.length > 2097152) { Fail("Invalid token vocabulary"); }
      NSMutableString *vocabulary = [NSMutableString string];
      for (NSString *line in [tokenText componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) { continue; }
        NSRange separator = [line rangeOfString:@" " options:NSBackwardsSearch];
        if (separator.location == NSNotFound) { Fail("Invalid token vocabulary line"); }
        [vocabulary appendFormat:@"%@\t-1\n", [line substringToIndex:separator.location]];
      }
      NSData *vocabularyData = [vocabulary dataUsingEncoding:NSUTF8StringEncoding];
      int fd = open(options.bpeVocab.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
      if (fd < 0) { Fail("Could not create contextual BPE vocabulary"); }
      size_t offset = 0;
      while (offset < vocabularyData.length) {
        ssize_t written = write(fd, static_cast<const char *>(vocabularyData.bytes) + offset, vocabularyData.length - offset);
        if (written <= 0) { close(fd); Fail("Could not write contextual BPE vocabulary"); }
        offset += written;
      }
      close(fd);
    }
    if (!IsRegularReadableFile(options.bpeVocab)) { Fail("Missing BPE vocabulary"); }
    config.hotwords_file = options.hotwordsFile.c_str();
    config.hotwords_score = options.hotwordsScore;
    config.model_config.modeling_unit = "bpe";
    config.model_config.bpe_vocab = options.bpeVocab.c_str();
  }

  const SherpaOnnxOfflineRecognizer *recognizer =
      SherpaOnnxCreateOfflineRecognizer(&config);
  if (recognizer == nullptr) {
    Fail("Failed to create the Parakeet recognizer");
  }
  // Submitted C values after successful create, not an internal GetConfig.
  WriteJSON(@{
    @"type": @"recognizer_configuration", @"schemaVersion": @1,
    @"configurationScope": @"submitted_after_successful_create", @"creationSucceeded": @YES,
    @"helperPID": @(getpid()), @"sessionID": [NSString stringWithUTF8String:options.sessionID.c_str()],
    @"captureMode": [NSString stringWithUTF8String:options.captureMode.c_str()],
    @"decodingMethod": [NSString stringWithUTF8String:config.decoding_method],
    @"maxActivePaths": @(config.max_active_paths), @"numThreads": @(config.model_config.num_threads),
    @"modelType": [NSString stringWithUTF8String:config.model_config.model_type],
    @"modelingUnit": config.model_config.modeling_unit
        ? static_cast<id>([NSString stringWithUTF8String:config.model_config.modeling_unit]) : NSNull.null,
    @"hotwordsScore": @(config.hotwords_score), @"hasHotwordsConfiguration": @(config.hotwords_file != nullptr),
    @"hasBPEVocabulary": @(config.model_config.bpe_vocab != nullptr)
  }, stderr);
  return Recognizer(recognizer, &SherpaOnnxDestroyOfflineRecognizer);
}

std::vector<float> ResampleChunk(const SherpaOnnxLinearResampler *resampler,
                               const float *samples, size_t count, bool flush) {
  if (count > INT32_MAX) {
    Fail("Audio chunk exceeds the resampler sample limit");
  }
  std::unique_ptr<const SherpaOnnxResampleOut,
                  decltype(&SherpaOnnxLinearResamplerResampleFree)> output(
      SherpaOnnxLinearResamplerResample(resampler, samples,
                                       static_cast<int32_t>(count), flush),
      &SherpaOnnxLinearResamplerResampleFree);
  if (!output || output->n < 0 || (output->n > 0 && !output->samples)) {
    Fail("Failed to resample audio");
  }
  if (output->n == 0) {
    return {};
  }
  return std::vector<float>(output->samples, output->samples + output->n);
}

std::vector<float> Resample(const float *samples, size_t count,
                           int32_t sourceRate) {
  if (samples == nullptr || count == 0 || sourceRate <= 0) {
    return {};
  }
  if (sourceRate == kTargetSampleRate) {
    return std::vector<float>(samples, samples + count);
  }

  Resampler resampler(SherpaOnnxCreateLinearResampler(
      sourceRate, kTargetSampleRate, 0, 0), &SherpaOnnxDestroyLinearResampler);
  if (!resampler) {
    Fail("Failed to create the audio resampler");
  }
  return ResampleChunk(resampler.get(), samples, count, true);
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

struct PendingUtterance {
  std::vector<float> samples;
  std::string audioSource;
  float startTime = 0;
  float endTime = 0;
};

class UtteranceSegmenter {
 public:
  UtteranceSegmenter(const Options &options, std::string audioSource,
                     std::function<void(PendingUtterance)> emit)
      : silenceThreshold_(options.silenceThreshold),
        trailingSilenceSeconds_(options.trailingSilenceSeconds),
        minimumUtteranceSeconds_(options.minimumUtteranceSeconds),
        maximumUtteranceSamples_(std::max<size_t>(1, static_cast<size_t>(
            std::llround(static_cast<double>(options.maximumUtteranceSeconds) * kTargetSampleRate)))),
        audioSource_(std::move(audioSource)),
        emit_(std::move(emit)) {}

  void Accept(const float *samples, size_t count, int32_t sourceRate) {
    if (!samples || count == 0 || sourceRate <= 0) {
      return;
    }
    if (sourceRate != sourceRate_) {
      Flush();
      sourceRate_ = sourceRate;
      resampler_.reset(sourceRate == kTargetSampleRate ? nullptr :
          SherpaOnnxCreateLinearResampler(sourceRate, kTargetSampleRate, 0, 0));
      if (sourceRate != kTargetSampleRate && !resampler_) {
        Fail("Failed to create the streaming audio resampler");
      }
    }
    AcceptResampled(resampler_ ? ResampleChunk(resampler_.get(), samples, count, false)
                              : std::vector<float>(samples, samples + count));
  }

  void Flush() {
    // End-of-input drains the filter; an automatic utterance split must not.
    if (resampler_) {
      AcceptResampled(ResampleChunk(resampler_.get(), nullptr, 0, true));
    }
    Emit();
  }

 private:
  void AcceptResampled(const std::vector<float> &resampled) {
    if (resampled.empty()) {
      return;
    }
    double energy = 0;
    for (float sample : resampled) {
      energy += static_cast<double>(sample) * sample;
    }
    const float rms =
        static_cast<float>(std::sqrt(energy / resampled.size()));
    const bool speechLike = rms >= silenceThreshold_;
    size_t offset = 0;
    while (offset < resampled.size()) {
      if (speechLike && samples_.empty()) {
        leadingSamples_ = preRoll_.size();
        segmentStart_ = std::max(0.F, audioClock_ -
            static_cast<float>(leadingSamples_) / kTargetSampleRate);
        samples_.swap(preRoll_);
        silenceSeconds_ = 0;
      }
      const bool active = !samples_.empty() || speechLike;
      const size_t count = active
          ? std::min(resampled.size() - offset, maximumUtteranceSamples_ - samples_.size())
          : resampled.size() - offset;
      const float duration = static_cast<float>(count) / kTargetSampleRate;
      if (active) {
        samples_.insert(samples_.end(), resampled.begin() + offset,
                        resampled.begin() + offset + count);
        silenceSeconds_ = speechLike ? 0 : silenceSeconds_ + duration;
      } else {
        preRoll_.insert(preRoll_.end(), resampled.begin() + offset, resampled.end());
        const size_t minimumSamples = std::min(maximumUtteranceSamples_,
            static_cast<size_t>(std::ceil(static_cast<double>(minimumUtteranceSeconds_) * kTargetSampleRate)));
        const size_t limit = std::min<size_t>(3200,
            maximumUtteranceSamples_ - std::max<size_t>(1, minimumSamples));
        if (preRoll_.size() > limit) {
          preRoll_.erase(preRoll_.begin(), preRoll_.end() - limit);
        }
      }
      offset += count;
      audioClock_ += duration;
      const float activeDuration =
          static_cast<float>(samples_.size() - leadingSamples_) / kTargetSampleRate;
      if (active && ((silenceSeconds_ >= trailingSilenceSeconds_ &&
                      activeDuration >= minimumUtteranceSeconds_) ||
                     samples_.size() == maximumUtteranceSamples_)) {
        Emit();
      }
    }
  }

  void Emit() {
    if (samples_.empty()) {
      preRoll_.clear();
      leadingSamples_ = 0;
      return;
    }
    const float duration =
        static_cast<float>(samples_.size()) / kTargetSampleRate;
    const float activeDuration =
        static_cast<float>(samples_.size() - leadingSamples_) / kTargetSampleRate;
    if (activeDuration >= minimumUtteranceSeconds_) {
      emit_(PendingUtterance{
          std::move(samples_),
          audioSource_,
          segmentStart_,
          segmentStart_ + duration,
      });
    }
    samples_.clear();
    preRoll_.clear();
    leadingSamples_ = 0;
    silenceSeconds_ = 0;
  }

 private:
  float silenceThreshold_;
  float trailingSilenceSeconds_;
  float minimumUtteranceSeconds_;
  size_t maximumUtteranceSamples_;
  std::string audioSource_;
  float audioClock_ = 0;
  float segmentStart_ = 0;
  float silenceSeconds_ = 0;
  int32_t sourceRate_ = kTargetSampleRate;
  Resampler resampler_{nullptr, &SherpaOnnxDestroyLinearResampler};
  std::vector<float> samples_;
  std::vector<float> preRoll_;
  size_t leadingSamples_ = 0;
  std::function<void(PendingUtterance)> emit_;
};

enum class DecodeEventType { Utterance, Stop };

struct DecodeEvent {
  DecodeEventType type = DecodeEventType::Utterance;
  PendingUtterance utterance;
  double audioSeconds = 0;
};

class DecodeQueue {
 public:
  static constexpr double kMaximumQueuedAudioSeconds = 60.0;

  void PushUtterance(PendingUtterance utterance) {
    if (utterance.samples.empty()) {
      return;
    }
    const double duration =
        static_cast<double>(utterance.samples.size()) / kTargetSampleRate;
    if (duration > kMaximumQueuedAudioSeconds) {
      Fail("One utterance exceeds the bounded decode queue");
    }

    std::unique_lock<std::mutex> lock(mutex_);
    notFull_.wait(lock, [&] {
      return queuedAudioSeconds_ + duration <= kMaximumQueuedAudioSeconds;
    });
    queuedAudioSeconds_ += duration;
    events_.push_back(DecodeEvent{
        DecodeEventType::Utterance,
        std::move(utterance),
        duration,
    });
    lock.unlock();
    notEmpty_.notify_one();
  }

  void PushStop() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      events_.push_back(DecodeEvent{DecodeEventType::Stop});
    }
    notEmpty_.notify_one();
  }

  DecodeEvent Pop() {
    std::unique_lock<std::mutex> lock(mutex_);
    notEmpty_.wait(lock, [&] { return !events_.empty(); });
    DecodeEvent event = std::move(events_.front());
    events_.pop_front();
    if (event.type == DecodeEventType::Utterance) {
      queuedAudioSeconds_ =
          std::max(0.0, queuedAudioSeconds_ - event.audioSeconds);
    }
    lock.unlock();
    notFull_.notify_one();
    return event;
  }

 private:
  std::mutex mutex_;
  std::condition_variable notEmpty_;
  std::condition_variable notFull_;
  std::deque<DecodeEvent> events_;
  double queuedAudioSeconds_ = 0;
};

void DecodeAndWrite(const SherpaOnnxOfflineRecognizer *recognizer,
                    const PendingUtterance &utterance) {
  const std::string text = Decode(recognizer, utterance.samples);
  NSString *trimmed = [[NSString stringWithUTF8String:text.c_str()]
      stringByTrimmingCharactersInSet:
          NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (trimmed.length == 0) {
    return;
  }
  NSString *audioSource =
      [NSString stringWithUTF8String:utterance.audioSource.c_str()];
  WriteJSON(@{
    @"segmentId" : NSUUID.UUID.UUIDString,
    @"text" : trimmed,
    @"isFinal" : @YES,
    @"startTime" : @(utterance.startTime),
    @"endTime" : @(utterance.endTime),
    @"confidence" : NSNull.null,
    @"source" : [NSString stringWithUTF8String:kSource],
    @"audioSource" : audioSource,
    @"speaker" : SpeakerForAudioSource(audioSource)
  });
}

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

int RunJSONL(const Options &options) {
  DecodeQueue decodeQueue;
  std::promise<void> decoderReady;
  std::future<void> decoderReadyFuture = decoderReady.get_future();
  std::thread decoderThread([&] {
    @autoreleasepool {
      Recognizer recognizer = CreateRecognizer(options);
      decoderReady.set_value();
      while (true) {
        DecodeEvent event = decodeQueue.Pop();
        if (event.type == DecodeEventType::Stop) {
          break;
        }
        @autoreleasepool {
          DecodeAndWrite(recognizer.get(), event.utterance);
        }
      }
    }
  });
  decoderReadyFuture.get();

  std::unordered_map<std::string, std::unique_ptr<UtteranceSegmenter>> segmenters;
  auto segmenterFor = [&](const std::string &audioSource) -> UtteranceSegmenter * {
    auto found = segmenters.find(audioSource);
    if (found != segmenters.end()) {
      return found->second.get();
    }
    auto segmenter = std::make_unique<UtteranceSegmenter>(
        options, audioSource,
        [&](PendingUtterance utterance) {
          decodeQueue.PushUtterance(std::move(utterance));
        });
    UtteranceSegmenter *pointer = segmenter.get();
    segmenters.emplace(audioSource, std::move(segmenter));
    return pointer;
  };
  auto flushAll = [&] {
    for (auto &entry : segmenters) {
      entry.second->Flush();
    }
  };

  std::fprintf(stderr, "native Parakeet ready session=%s capture_mode=%s\n",
               options.sessionID.c_str(), options.captureMode.c_str());
  std::string line;
  while (std::getline(std::cin, line)) {
    if (line.empty()) {
      continue;
    }
    bool shouldStop = false;
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
            : [NSString
                  stringWithUTF8String:DefaultAudioSource(options).c_str()];
        if (![sourceValue isEqualToString:@"microphone"] &&
            ![sourceValue isEqualToString:@"systemAudio"]) {
          Fail("Unsupported audioSource");
        }
        segmenterFor(sourceValue.UTF8String)
            ->Accept(mono.data(), mono.size(), sampleRate);
      } else if ([type isEqualToString:@"flush"]) {
        flushAll();
      } else if ([type isEqualToString:@"stop"]) {
        shouldStop = true;
      } else {
        Fail("Unsupported JSONL event type");
      }
    }
    if (shouldStop) {
      break;
    }
  }

  flushAll();
  decodeQueue.PushStop();
  decoderThread.join();
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
    if (options.jsonl && !options.probeModel && options.wavPath.empty()) {
      return RunJSONL(options);
    }
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
    Fail("Conflicting Parakeet runtime modes");
  }
}
