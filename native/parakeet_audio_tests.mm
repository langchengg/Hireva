#include <cassert>
#ifndef HELPER_SOURCE
#define HELPER_SOURCE "parakeet_asr_helper.mm"
#endif
#define main hireva_model_main
#include HELPER_SOURCE
#undef main

void CheckFilteredAudio() {
  std::vector<float> low(48000), high(48000);
  for (size_t i=0; i<low.size(); ++i) {
    low[i]=std::sin(2*M_PI*1000*i/48000);
    high[i]=std::sin(2*M_PI*12000*i/48000);
  }
  const auto expected=Resample(low.data(),low.size(),48000);
  const auto filtered=Resample(high.data(),high.size(),48000);
  double lowEnergy=0, highEnergy=0, centralHighEnergy=0;
  for (float x:expected) lowEnergy+=x*x;
  for (float x:filtered) highEnergy+=x*x;
  for(size_t i=200;i<filtered.size()-200;++i) centralHighEnergy+=filtered[i]*filtered[i];
  assert(expected.size()==16000 && filtered.size()==16000);
  std::cerr << "resampler RMS 1k=" << std::sqrt(lowEnergy/16000)
            << " 12k=" << std::sqrt(highEnergy/16000) << "\n";
  assert(std::sqrt(lowEnergy/16000)>.69);
  // Startup/end ringing is separate from the frozen steady-state attenuation check.
  assert(std::sqrt(centralHighEnergy/15600)/std::sqrt(.5)<.01);

  Options options;
  options.silenceThreshold=0;
  std::vector<PendingUtterance> a,b;
  UtteranceSegmenter first(options,"systemAudio",[&](PendingUtterance u){a.push_back(std::move(u));});
  UtteranceSegmenter second(options,"microphone",[&](PendingUtterance u){b.push_back(std::move(u));});
  const std::vector<float> other(960,.1F);
  for(size_t offset=0;offset<low.size();offset+=960) {
    first.Accept(low.data()+offset,960,48000);
    second.Accept(other.data(),other.size(),48000);
  }
  first.Flush(); first.Flush(); second.Flush(); second.Flush();
  assert(a.size()==1 && b.size()==1 && a[0].samples.size()==16000 && b[0].samples.size()==16000);
  for(size_t i=0;i<expected.size();++i) assert(std::abs(a[0].samples[i]-expected[i])<.000001F);
  assert(a[0].audioSource=="systemAudio" && b[0].audioSource=="microphone");
  assert(std::abs(b[0].samples[8000]-.1F)<.0001F);

  a.clear();
  UtteranceSegmenter bounded(options,"systemAudio",[&](PendingUtterance u){a.push_back(std::move(u));});
  for(int i=0;i<720;++i) bounded.Accept(other.data(),other.size(),48000);
  bounded.Flush(); bounded.Flush();
  size_t total=0;
  for(const auto &u:a){assert(u.samples.size()<=224000);total+=u.samples.size();}
  assert(a.size()==2 && total==230400);

  a.clear();
  UtteranceSegmenter shortTail(options,"systemAudio",[&](PendingUtterance u){a.push_back(std::move(u));});
  for(int i=0;i<710;++i) shortTail.Accept(other.data(),other.size(),48000);
  shortTail.Flush(); shortTail.Flush();
  assert(a.size()==1 && a[0].samples.size()==224000);

  a.clear();
  UtteranceSegmenter changed(options,"systemAudio",[&](PendingUtterance u){a.push_back(std::move(u));});
  for(int i=0;i<25;++i) changed.Accept(other.data(),other.size(),48000);
  const std::vector<float> direct(320,.2F);
  for(int i=0;i<25;++i) changed.Accept(direct.data(),direct.size(),16000);
  changed.Flush(); changed.Flush();
  assert(a.size()==2 && a[0].samples.size()==8000 && a[1].samples.size()==8000);
  assert(std::abs(a[1].startTime-.5F)<.00001F && std::abs(a[1].endTime-1.F)<.00001F);
  assert(std::all_of(a[1].samples.begin(),a[1].samples.end(),[](float x){return x==.2F;}));
}

int main() {
  CheckFilteredAudio();
  Options options;
  std::vector<PendingUtterance> a, b;
  UtteranceSegmenter first(options, "systemAudio", [&](PendingUtterance u) { a.push_back(std::move(u)); });
  UtteranceSegmenter second(options, "microphone", [&](PendingUtterance u) { b.push_back(std::move(u)); });
  const std::vector<float> quiet(320, .002F), loud(320, .1F);
  for (int i=0;i<25;++i) first.Accept(quiet.data(), quiet.size(), 16000);
  for (int i=0;i<20;++i) first.Accept(loud.data(), loud.size(), 16000);
  first.Flush(); first.Flush();
  for (int i=0;i<20;++i) second.Accept(loud.data(), loud.size(), 16000);
  second.Flush();
  if (a.size()!=1 || a[0].samples.size()!=9600 ||
      !std::all_of(a[0].samples.begin(),a[0].samples.begin()+3200,[](float x){return x==.002F;}) ||
      !std::all_of(a[0].samples.begin()+3200,a[0].samples.end(),[](float x){return x==.1F;}) ||
      std::abs(a[0].startTime-.3F)>.00001F || std::abs(a[0].endTime-.9F)>.00001F ||
      b.size()!=1 || b[0].samples.size()!=6400 || b[0].startTime!=0 ||
      a[0].audioSource!="systemAudio" || b[0].audioSource!="microphone") {
    std::cerr << "FAIL: quiet onset / bounded prefix / source / duplicate flush\n"; return 1;
  }
  a.clear();
  for (int i=0;i<20;++i) first.Accept(quiet.data(), quiet.size(), 16000);
  for (int i=0;i<10;++i) first.Accept(loud.data(), loud.size(), 16000);
  first.Flush();
  if (!a.empty()) { std::cerr << "FAIL: leading quiet audio enlarged minimum eligibility\n"; return 1; }
  for (int i=0;i<20;++i) first.Accept(quiet.data(), quiet.size(), 16000);
  first.Flush();
  for (int i=0;i<20;++i) first.Accept(loud.data(), loud.size(), 16000);
  first.Flush();
  if (a.size()!=1 || a[0].samples.size()!=6400) { std::cerr << "FAIL: explicit quiet flush retained obsolete prefix\n"; return 1; }
  a.clear();
  for (int i=0;i<20;++i) first.Accept(quiet.data(), quiet.size(), 16000);
  for (int i=0;i<720;++i) first.Accept(loud.data(), loud.size(), 16000);
  first.Flush(); first.Flush();
  size_t total=0;
  for (const auto &u:a) {
    total+=u.samples.size();
    if(u.samples.size()>224000) { std::cerr << "FAIL: maximum14s audio exceeded\n"; return 1; }
  }
  if(a.size()!=2 || total!=233600) { std::cerr << "FAIL: maximum split lost/duplicated samples\n"; return 1; }
  a.clear();
  UtteranceSegmenter startBoundary(options, "systemAudio", [&](PendingUtterance u) { a.push_back(std::move(u)); });
  for (int i=0;i<10;++i) startBoundary.Accept(quiet.data(), quiet.size(), 16000);
  for (int i=0;i<20;++i) startBoundary.Accept(loud.data(), loud.size(), 16000);
  startBoundary.Flush();
  if(a.size()!=1 || a[0].startTime!=0) { std::cerr << "FAIL: prefix start negative\n"; return 1; }
  a.clear();
  UtteranceSegmenter minimumBoundary(options, "systemAudio", [&](PendingUtterance u) { a.push_back(std::move(u)); });
  for (int i=0;i<9;++i) minimumBoundary.Accept(quiet.data(), quiet.size(), 16000);
  const std::vector<float> exactMinimum(5600,.1F);
  minimumBoundary.Accept(exactMinimum.data(),exactMinimum.size(),16000);
  minimumBoundary.Flush();
  if(a.size()!=1 || a[0].samples.size()!=8480) { std::cerr << "FAIL: exact350ms eligibility rejected\n"; return 1; }
  a.clear();
  options.maximumUtteranceSeconds=options.minimumUtteranceSeconds;
  UtteranceSegmenter tightMaximum(options,"systemAudio",[&](PendingUtterance u){a.push_back(std::move(u));});
  for(int i=0;i<20;++i) tightMaximum.Accept(quiet.data(),quiet.size(),16000);
  tightMaximum.Accept(exactMinimum.data(),exactMinimum.size(),16000);
  tightMaximum.Flush();
  if(a.size()!=1 || a[0].samples.size()!=5600) { std::cerr << "FAIL: prefix consumed minimum eligibility at tight maximum\n"; return 1; }
  std::cout << "PASS: filtered streaming audio, source/rate boundaries, exact14s split, and seven segment boundaries; zero recognizer/device starts\n";
  return 0;
}
