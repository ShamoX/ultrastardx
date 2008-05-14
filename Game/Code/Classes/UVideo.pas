{##############################################################################
 #                    FFmpeg support for UltraStar deluxe                     #
 #                                                                            #
 #    Created by b1indy                                                       #
 #    based on 'An ffmpeg and SDL Tutorial' (http://www.dranger.com/ffmpeg/)  #
 #    with modifications by Jay Binks <jaybinks@gmail.com>                    #
 #                                                                            #
 # http://www.mail-archive.com/fpc-pascal@lists.freepascal.org/msg09949.html  #
 # http://www.nabble.com/file/p11795857/mpegpas01.zip                         #
 #                                                                            #
 ##############################################################################}

unit UVideo;

//{$define DebugDisplay}  // uncomment if u want to see the debug stuff
//{$define DebugFrames}
//{$define VideoBenchmark}
//{$define Info}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

(*
  TODO: look into av_read_play
*)

// use BGR-format for accelerated colorspace conversion with swscale 
{.$DEFINE PIXEL_FMT_BGR}

implementation

uses
  SDL,
  textgl,
  avcodec,
  avformat,
  avutil,
  avio,
  rational,
  {$IFDEF UseSWScale}
  swscale,
  {$ENDIF}
  math,
  gl,
  glext,
  SysUtils,
  UCommon,
  UConfig,
  ULog,
  UMusic,
  UGraphicClasses,
  UGraphic;

const
{$IFDEF PIXEL_FMT_BGR}
  PIXEL_FMT_OPENGL = GL_BGR;
  PIXEL_FMT_FFMPEG = PIX_FMT_BGR24;
{$ELSE}
  PIXEL_FMT_OPENGL = GL_RGB;
  PIXEL_FMT_FFMPEG = PIX_FMT_RGB24;
{$ENDIF}

type
  TVideoPlayback_ffmpeg = class( TInterfacedObject, IVideoPlayback )
  private
    fVideoOpened,
    fVideoPaused: Boolean;

    VideoStream: PAVStream;
    VideoStreamIndex : Integer;
    VideoFormatContext: PAVFormatContext;
    VideoCodecContext: PAVCodecContext;
    VideoCodec: PAVCodec;

    AVFrame: PAVFrame;
    AVFrameRGB: PAVFrame;
    FrameBuffer: PByte;

    {$IFDEF UseSWScale}
    SoftwareScaleContext: PSwsContext;
    {$ENDIF}

    fVideoTex: GLuint;
    TexWidth, TexHeight: Cardinal;
    ScaledVideoWidth, ScaledVideoHeight: Real;
    
    VideoAspect: Real;
    VideoTimeBase, VideoTime: Extended;
    fLoopTime: Extended;

    EOF: boolean;
    Loop: boolean;

    procedure Reset();
    function DecodeFrame(var AVPacket: TAVPacket; out pts: double): boolean;
    function FindStreamIDs( const aFormatCtx : PAVFormatContext; out aFirstVideoStream, aFirstAudioStream : integer ): boolean;
    procedure SynchronizeVideo(pFrame: PAVFrame; var pts: double);
  public
    constructor Create();
    function    GetName: String;
    procedure   Init();

    function    Open(const aFileName : string): boolean; // true if succeed
    procedure   Close;

    procedure   Play;
    procedure   Pause;
    procedure   Stop;

    procedure   SetPosition(Time: real);
    function    GetPosition: real;

    procedure   GetFrame(Time: Extended);
    procedure   DrawGL(Screen: integer);

  end;

var
  singleton_VideoFFMpeg : IVideoPlayback;



function FFMpegErrorString(Errnum: integer): string;
begin
  case Errnum of
    AVERROR_IO:      Result := 'AVERROR_IO';
    AVERROR_NUMEXPECTED: Result := 'AVERROR_NUMEXPECTED';
    AVERROR_INVALIDDATA: Result := 'AVERROR_INVALIDDATA';
    AVERROR_NOMEM:   Result := 'AVERROR_NOMEM';
    AVERROR_NOFMT:   Result := 'AVERROR_NOFMT';
    AVERROR_NOTSUPP: Result := 'AVERROR_NOTSUPP';
    AVERROR_NOENT:   Result := 'AVERROR_NOENT';
    else Result := 'AVERROR_#'+inttostr(Errnum);
  end;
end;

// These are called whenever we allocate a frame buffer.
// We use this to store the global_pts in a frame at the time it is allocated.
function PtsGetBuffer(pCodecCtx: PAVCodecContext; pFrame: PAVFrame): integer; cdecl;
var
  pts: Pint64;
  VideoPktPts: Pint64;
begin
  Result := avcodec_default_get_buffer(pCodecCtx, pFrame);
  VideoPktPts := pCodecCtx^.opaque;
  if (VideoPktPts <> nil) then
  begin
    // Note: we must copy the pts instead of passing a pointer, because the packet
    // (and with it the pts) might change before a frame is returned by av_decode_video.
    pts := av_malloc(sizeof(int64));
    pts^ := VideoPktPts^;
    pFrame^.opaque := pts;
  end;
end;

procedure PtsReleaseBuffer(pCodecCtx: PAVCodecContext; pFrame: PAVFrame); cdecl;
begin
  if (pFrame <> nil) then
    av_freep(@pFrame^.opaque);
  avcodec_default_release_buffer(pCodecCtx, pFrame);
end;


{*------------------------------------------------------------------------------
 * TVideoPlayback_ffmpeg
 *------------------------------------------------------------------------------}

function  TVideoPlayback_ffmpeg.GetName: String;
begin
  result := 'FFMpeg_Video';
end;

{
  @param(aFormatCtx is a PAVFormatContext returned from av_open_input_file )
  @param(aFirstVideoStream is an OUT value of type integer, this is the index of the video stream)
  @param(aFirstAudioStream is an OUT value of type integer, this is the index of the audio stream)
  @returns(@true on success, @false otherwise)
}
function TVideoPlayback_ffmpeg.FindStreamIDs(const aFormatCtx: PAVFormatContext; out aFirstVideoStream, aFirstAudioStream: integer): boolean;
var
  i : integer;
  st : PAVStream;
begin
  // Find the first video stream
  aFirstAudioStream := -1;
  aFirstVideoStream := -1;

  {$IFDEF DebugDisplay}
  debugwriteln('aFormatCtx.nb_streams : ' + inttostr(aFormatCtx.nb_streams));
  {$ENDIF}

  for i := 0 to aFormatCtx.nb_streams-1 do
  begin
    st := aFormatCtx.streams[i];

    if (st.codec.codec_type = CODEC_TYPE_VIDEO) and
       (aFirstVideoStream < 0) then
    begin
      aFirstVideoStream := i;
    end;

    if (st.codec.codec_type = CODEC_TYPE_AUDIO) and
       (aFirstAudioStream < 0) then
    begin
      aFirstAudioStream := i;
    end;
  end;

  // return true if either an audio- or video-stream was found
  result := (aFirstAudioStream > -1) or
            (aFirstVideoStream > -1) ;
end;

procedure TVideoPlayback_ffmpeg.SynchronizeVideo(pFrame: PAVFrame; var pts: double);
var
  FrameDelay: double;
begin
  if (pts <> 0) then
  begin
    // if we have pts, set video clock to it
    VideoTime := pts;
  end else
  begin
    // if we aren't given a pts, set it to the clock
    pts := VideoTime;
  end;
  // update the video clock
  FrameDelay := av_q2d(VideoCodecContext^.time_base);
  // if we are repeating a frame, adjust clock accordingly
  FrameDelay := FrameDelay + pFrame^.repeat_pict * (FrameDelay * 0.5);
  VideoTime := VideoTime + FrameDelay;
end;

function TVideoPlayback_ffmpeg.DecodeFrame(var AVPacket: TAVPacket; out pts: double): boolean;
var
  FrameFinished: Integer;
  VideoPktPts: int64;
  pbIOCtx: PByteIOContext;
  errnum: integer;
begin
  Result := false;
  FrameFinished := 0;

  if EOF then
    Exit;

  // read packets until we have a finished frame (or there are no more packets)
  while (FrameFinished = 0) do
  begin
    errnum := av_read_frame(VideoFormatContext, AVPacket);
    if (errnum < 0) then
    begin
      // failed to read a frame, check reason

      {$IF (LIBAVFORMAT_VERSION_MAJOR >= 52)}
      pbIOCtx := VideoFormatContext^.pb;
      {$ELSE}
      pbIOCtx := @VideoFormatContext^.pb;
      {$IFEND}

      // check for end-of-file (eof is not an error)
      if (url_feof(pbIOCtx) <> 0) then
      begin
        EOF := true;
        Exit;
      end;

      // check for errors
      if (url_ferror(pbIOCtx) <> 0) then
        Exit;

      // url_feof() does not detect an EOF for some mov-files (e.g. deluxe.mov)
      // so we have to do it this way.
      if ((VideoFormatContext^.file_size <> 0) and
          (pbIOCtx^.pos >= VideoFormatContext^.file_size)) then
      begin
        EOF := true;
        Exit;
      end;

      // no error -> wait for user input
      SDL_Delay(100);
      continue;
    end;

    // if we got a packet from the video stream, then decode it
    if (AVPacket.stream_index = VideoStreamIndex) then
    begin
      // save pts to be stored in pFrame in first call of PtsGetBuffer()
      VideoPktPts := AVPacket.pts;
      VideoCodecContext^.opaque := @VideoPktPts;

      // decode packet
      avcodec_decode_video(VideoCodecContext, AVFrame,
          frameFinished, AVPacket.data, AVPacket.size);

      // reset opaque data
      VideoCodecContext^.opaque := nil;

      // update pts
      if (AVPacket.dts <> AV_NOPTS_VALUE) then
      begin
        pts := AVPacket.dts;
      end
      else if ((AVFrame^.opaque <> nil) and
               (Pint64(AVFrame^.opaque)^ <> AV_NOPTS_VALUE)) then
      begin
        pts := Pint64(AVFrame^.opaque)^;
      end
      else
      begin
        pts := 0;
      end;
      pts := pts * av_q2d(VideoStream^.time_base);

      // synchronize on each complete frame
      if (frameFinished <> 0) then
        SynchronizeVideo(AVFrame, pts);
    end;

    // free the packet from av_read_frame
    av_free_packet( @AVPacket );
  end;

  Result := true;
end;

procedure TVideoPlayback_ffmpeg.GetFrame(Time: Extended);
var
  AVPacket: TAVPacket;
  errnum: Integer;
  myTime: Extended;
  TimeDifference: Extended;
  DropFrameCount: Integer;
  pts: double;
  i: Integer;
const
  FRAME_DROPCOUNT = 3;
begin
  if not fVideoOpened then
    Exit;

  if fVideoPaused then
    Exit;

  // current time, relative to last loop (if any)
  myTime := Time - fLoopTime;
  // time since the last frame was returned
  TimeDifference := myTime - VideoTime;

  {$IFDEF DebugDisplay}
  DebugWriteln('Time:      '+inttostr(floor(Time*1000)) + sLineBreak +
               'VideoTime: '+inttostr(floor(VideoTime*1000)) + sLineBreak +
               'TimeBase:  '+inttostr(floor(VideoTimeBase*1000)) + sLineBreak +
               'TimeDiff:  '+inttostr(floor(TimeDifference*1000)));
  {$endif}

  // check if a new frame is needed
  if (VideoTime <> 0) and (TimeDifference < VideoTimeBase) then
  begin
    {$ifdef DebugFrames}
    // frame delay debug display
    GoldenRec.Spawn(200,15,1,16,0,-1,ColoredStar,$00ff00);
    {$endif}

    {$IFDEF DebugDisplay}
    DebugWriteln('not getting new frame' + sLineBreak +
        'Time:      '+inttostr(floor(Time*1000)) + sLineBreak +
        'VideoTime: '+inttostr(floor(VideoTime*1000)) + sLineBreak +
        'TimeBase:  '+inttostr(floor(VideoTimeBase*1000)) + sLineBreak +
        'TimeDiff:  '+inttostr(floor(TimeDifference*1000)));
    {$endif}

    // we do not need a new frame now
    Exit;
  end;

  // update video-time to the next frame
  VideoTime := VideoTime + VideoTimeBase;
  TimeDifference := myTime - VideoTime;

  // check if we have to skip frames
  if (TimeDifference >= FRAME_DROPCOUNT*VideoTimeBase) then
  begin
    {$IFDEF DebugFrames}
    //frame drop debug display
    GoldenRec.Spawn(200,55,1,16,0,-1,ColoredStar,$ff0000);
    {$ENDIF}
    {$IFDEF DebugDisplay}
    DebugWriteln('skipping frames' + sLineBreak +
        'TimeBase:  '+inttostr(floor(VideoTimeBase*1000)) + sLineBreak +
        'TimeDiff:  '+inttostr(floor(TimeDifference*1000)));
    {$endif}

    // update video-time
    DropFrameCount := Trunc(TimeDifference / VideoTimeBase);
    VideoTime := VideoTime + DropFrameCount*VideoTimeBase;

    // skip half of the frames, this is much smoother than to skip all at once
    for i := 1 to DropFrameCount (*div 2*) do
      DecodeFrame(AVPacket, pts);
  end;

  {$IFDEF VideoBenchmark}
  Log.BenchmarkStart(15);
  {$ENDIF}

  if (not DecodeFrame(AVPacket, pts)) then
  begin
    if Loop then
    begin
      // Record the time we looped. This is used to keep the loops in time. otherwise they speed
      SetPosition(0);
      fLoopTime := Time;
    end;
    Exit;
  end;

  // otherwise we convert the pixeldata from YUV to RGB
  {$IFDEF UseSWScale}
  errnum := sws_scale(SoftwareScaleContext, @(AVFrame.data), @(AVFrame.linesize),
          0, VideoCodecContext^.Height,
          @(AVFrameRGB.data), @(AVFrameRGB.linesize));
  {$ELSE}
  errnum := img_convert(PAVPicture(AVFrameRGB), PIXEL_FMT_FFMPEG,
            PAVPicture(AVFrame), VideoCodecContext^.pix_fmt,
			      VideoCodecContext^.width, VideoCodecContext^.height);
  {$ENDIF}
  
  if (errnum < 0) then
  begin
    Log.LogError('Image conversion failed', 'TVideoPlayback_ffmpeg.GetFrame');
    Exit;
  end;

  {$IFDEF VideoBenchmark}
  Log.BenchmarkEnd(15);
  Log.BenchmarkStart(16);
  {$ENDIF}

  // TODO: data is not padded, so we will need to tell OpenGL.
  //   Or should we add padding with avpicture_fill? (check which one is faster)
  //glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

  glBindTexture(GL_TEXTURE_2D, fVideoTex);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
      VideoCodecContext^.width, VideoCodecContext^.height,
      PIXEL_FMT_OPENGL, GL_UNSIGNED_BYTE, AVFrameRGB^.data[0]);

  {$ifdef DebugFrames}
  //frame decode debug display
  GoldenRec.Spawn(200, 35, 1, 16, 0, -1, ColoredStar, $ffff00);
  {$endif}

  {$IFDEF VideoBenchmark}
  Log.BenchmarkEnd(16);
  Log.LogBenchmark('FFmpeg', 15);
  Log.LogBenchmark('Texture', 16);
  {$ENDIF}
end;

procedure TVideoPlayback_ffmpeg.DrawGL(Screen: integer);
var
  TexVideoRightPos, TexVideoLowerPos: Single;
  ScreenLeftPos,  ScreenRightPos: Single;
  ScreenUpperPos, ScreenLowerPos: Single;
const
  ScreenMidPosX = 400.0;
  ScreenMidPosY = 300.0;
begin
  // have a nice black background to draw on (even if there were errors opening the vid)
  if (Screen = 1) then
  begin
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);
  end;

  // exit if there's nothing to draw
  if (not fVideoOpened) then
    Exit;

  {$IFDEF VideoBenchmark}
  Log.BenchmarkStart(15);
  {$ENDIF}

  TexVideoRightPos := VideoCodecContext^.width  / TexWidth;
  TexVideoLowerPos := VideoCodecContext^.height / TexHeight;
  ScreenLeftPos  := ScreenMidPosX - ScaledVideoWidth/2;
  ScreenRightPos := ScreenMidPosX + ScaledVideoWidth/2;
  ScreenUpperPos := ScreenMidPosY - ScaledVideoHeight/2;
  ScreenLowerPos := ScreenMidPosY + ScaledVideoHeight/2;

  // we could use blending for brightness control, but do we need this?
  glDisable(GL_BLEND);

  // TODO: disable other stuff like lightning, etc. 

  glEnable(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, fVideoTex);
  glColor3f(1, 1, 1);
  glBegin(GL_QUADS);
    // upper-left coord
    glTexCoord2f(0, 0);
    glVertex2f(ScreenLeftPos, ScreenUpperPos);
    // lower-left coord
    glTexCoord2f(0, TexVideoLowerPos);
    glVertex2f(ScreenLeftPos, ScreenLowerPos);
    // lower-right coord
    glTexCoord2f(TexVideoRightPos, TexVideoLowerPos);
    glVertex2f(ScreenRightPos, ScreenLowerPos);
    // upper-right coord
    glTexCoord2f(TexVideoRightPos, 0);
    glVertex2f(ScreenRightPos, ScreenUpperPos);
  glEnd;
  glDisable(GL_TEXTURE_2D);

  {$IFDEF VideoBenchmark}
  Log.BenchmarkEnd(15);
  Log.LogBenchmark('DrawGL', 15);
  {$ENDIF}

  {$IFDEF Info}
  if (fVideoSkipTime+VideoTime+VideoTimeBase < 0) then
  begin
    glColor4f(0.7, 1, 0.3, 1);
    SetFontStyle (1);
    SetFontItalic(False);
    SetFontSize(9);
    SetFontPos (300, 0);
    glPrint('Delay due to negative VideoGap');
    glColor4f(1, 1, 1, 1);
  end;
  {$ENDIF}

  {$IFDEF DebugFrames}
    glColor4f(0, 0, 0, 0.2);
    glbegin(GL_QUADS);
      glVertex2f(0, 0);
      glVertex2f(0, 70);
      glVertex2f(250, 70);
      glVertex2f(250, 0);
    glEnd;

    glColor4f(1, 1, 1, 1);
    SetFontStyle (1);
    SetFontItalic(False);
    SetFontSize(9);
    SetFontPos (5, 0);
    glPrint('delaying frame');
    SetFontPos (5, 20);
    glPrint('fetching frame');
    SetFontPos (5, 40);
    glPrint('dropping frame');
  {$ENDIF}
end;

constructor TVideoPlayback_ffmpeg.Create();
begin
  inherited;
  Reset();
  av_register_all();
end;

procedure TVideoPlayback_ffmpeg.Init();
begin
  glGenTextures(1, PGLuint(@fVideoTex));
end;

procedure TVideoPlayback_ffmpeg.Reset();
begin
  // close previously opened video
  Close();

  fVideoOpened       := False;
  fVideoPaused       := False;
  VideoTimeBase      := 0;
  VideoTime          := 0;
  VideoStream := nil;
  VideoFormatContext := nil;
  VideoCodecContext  := nil;
  VideoStreamIndex := -1;

  AVFrame     := nil;
  AVFrameRGB  := nil;
  FrameBuffer := nil;

  EOF := false;

  // TODO: do we really want this by default?
  Loop := true;
  fLoopTime := 0;
end;

function TVideoPlayback_ffmpeg.Open(const aFileName : string): boolean; // true if succeed
var
  errnum: Integer;
  err: GLenum;
  AudioStreamIndex: integer;

  procedure CleanOnError();
  begin
    if (VideoCodecContext <> nil) then
      avcodec_close(VideoCodecContext);
    if (VideoFormatContext <> nil) then
      av_close_input_file(VideoFormatContext);
    av_free(AVFrameRGB);
    av_free(AVFrame);
    av_free(FrameBuffer);
  end;

begin
  Result := false;

  Reset();

  errnum := av_open_input_file(VideoFormatContext, pchar( aFileName ), nil, 0, nil);
  if (errnum <> 0) then
  begin
    Log.LogError('Failed to open file "'+aFileName+'" ('+FFMpegErrorString(errnum)+')');
    Exit;
  end;

  // update video info
  if (av_find_stream_info(VideoFormatContext) < 0) then
  begin
    Log.LogError('No stream info found', 'TVideoPlayback_ffmpeg.Open');
    CleanOnError();
    Exit;
  end;
  Log.LogInfo('VideoStreamIndex : ' + inttostr(VideoStreamIndex), 'TVideoPlayback_ffmpeg.Open');

  // find video stream
  FindStreamIDs(VideoFormatContext, VideoStreamIndex, AudioStreamIndex);
  if (VideoStreamIndex < 0) then
  begin
    Log.LogError('No video stream found', 'TVideoPlayback_ffmpeg.Open');
    CleanOnError();
    Exit;
  end;

  VideoStream := VideoFormatContext^.streams[VideoStreamIndex];
  VideoCodecContext := VideoStream^.codec;

  VideoCodec := avcodec_find_decoder(VideoCodecContext^.codec_id);
  if (VideoCodec = nil) then
  begin
    Log.LogError('No matching codec found', 'TVideoPlayback_ffmpeg.Open');
    CleanOnError();
    Exit;
  end;

  // set debug options
  VideoCodecContext^.debug_mv := 0;
  VideoCodecContext^.debug := 0;

  // detect bug-workarounds automatically
  VideoCodecContext^.workaround_bugs := FF_BUG_AUTODETECT;
  // error resilience strategy (careful/compliant/agressive/very_aggressive)
  //VideoCodecContext^.error_resilience := FF_ER_CAREFUL; //FF_ER_COMPLIANT;
  // allow non spec compliant speedup tricks.
  //VideoCodecContext^.flags2 := VideoCodecContext^.flags2 or CODEC_FLAG2_FAST;

  errnum := avcodec_open(VideoCodecContext, VideoCodec);
  if (errnum < 0) then
  begin
    Log.LogError('No matching codec found', 'TVideoPlayback_ffmpeg.Open');
    CleanOnError();
    Exit;
  end;

  // register custom callbacks for pts-determination 
  VideoCodecContext^.get_buffer := PtsGetBuffer;
  VideoCodecContext^.release_buffer := PtsReleaseBuffer;

  {$ifdef DebugDisplay}
  DebugWriteln('Found a matching Codec: '+ VideoCodecContext^.Codec.Name + sLineBreak +
    sLineBreak +
    '  Width = '+inttostr(VideoCodecContext^.width) +
    ', Height='+inttostr(VideoCodecContext^.height) + sLineBreak +
    '  Aspect    : '+inttostr(VideoCodecContext^.sample_aspect_ratio.num) + '/' +
                     inttostr(VideoCodecContext^.sample_aspect_ratio.den) + sLineBreak +
    '  Framerate : '+inttostr(VideoCodecContext^.time_base.num) + '/' +
                     inttostr(VideoCodecContext^.time_base.den));
  {$endif}

  // allocate space for decoded frame and rgb frame
  AVFrame := avcodec_alloc_frame();
  AVFrameRGB := avcodec_alloc_frame();
  FrameBuffer := av_malloc(avpicture_get_size(PIXEL_FMT_FFMPEG,
      VideoCodecContext^.width, VideoCodecContext^.height));

  if ((AVFrame = nil) or (AVFrameRGB = nil) or (FrameBuffer = nil)) then
  begin
    Log.LogError('Failed to allocate buffers', 'TVideoPlayback_ffmpeg.Open');
    CleanOnError();
    Exit;
  end;

  // TODO: pad data for OpenGL to GL_UNPACK_ALIGNMENT
  // (otherwise video will be distorted if width/height is not a multiple of the alignment)
  errnum := avpicture_fill(PAVPicture(AVFrameRGB), FrameBuffer, PIXEL_FMT_FFMPEG,
      VideoCodecContext^.width, VideoCodecContext^.height);
  if (errnum < 0) then
  begin
    Log.LogError('avpicture_fill failed: ' + FFMpegErrorString(errnum), 'TVideoPlayback_ffmpeg.Open');
    CleanOnError();
    Exit;
  end;

  // calculate some information for video display
  VideoAspect := av_q2d(VideoCodecContext^.sample_aspect_ratio);
  if (VideoAspect = 0) then
    VideoAspect := VideoCodecContext^.width /
                   VideoCodecContext^.height
  else
    VideoAspect := VideoAspect * VideoCodecContext^.width /
                                 VideoCodecContext^.height;

  ScaledVideoWidth := 800.0;
  ScaledVideoHeight := 800.0 / VideoAspect;

  VideoTimeBase := 1/av_q2d(VideoStream^.r_frame_rate);

  // hack to get reasonable timebase (for divx and others)
  if (VideoTimeBase < 0.02) then // 0.02 <-> 50 fps
  begin
    VideoTimeBase := av_q2d(VideoStream^.r_frame_rate);
    while (VideoTimeBase > 50) do
      VideoTimeBase := VideoTimeBase/10;
    VideoTimeBase := 1/VideoTimeBase;
  end;

  Log.LogInfo('VideoTimeBase: ' + floattostr(VideoTimeBase), 'TVideoPlayback_ffmpeg.Open');
  Log.LogInfo('Framerate: '+inttostr(floor(1/VideoTimeBase))+'fps', 'TVideoPlayback_ffmpeg.Open');

  {$IFDEF UseSWScale}
  // if available get a SWScale-context -> faster than the deprecated img_convert().
  // SWScale has accelerated support for PIX_FMT_RGB32/PIX_FMT_BGR24/PIX_FMT_BGR565/PIX_FMT_BGR555.
  // Note: PIX_FMT_RGB32 is a BGR- and not an RGB-format (maybe a bug)!!!
  // The BGR565-formats (GL_UNSIGNED_SHORT_5_6_5) is way too slow because of its
  // bad OpenGL support. The BGR formats have MMX(2) implementations but no speed-up
  // could be observed in comparison to the RGB versions.
  SoftwareScaleContext := sws_getContext(
      VideoCodecContext^.width, VideoCodecContext^.height,
      integer(VideoCodecContext^.pix_fmt),
      VideoCodecContext^.width, VideoCodecContext^.height,
      integer(PIXEL_FMT_FFMPEG),
      SWS_FAST_BILINEAR, nil, nil, nil);
  if (SoftwareScaleContext = nil) then
  begin
    Log.LogError('Failed to get swscale context', 'TVideoPlayback_ffmpeg.Open');
    CleanOnError();
    Exit;
  end;
  {$ENDIF}

  TexWidth   := Round(Power(2, Ceil(Log2(VideoCodecContext^.width))));
  TexHeight  := Round(Power(2, Ceil(Log2(VideoCodecContext^.height))));

  // we retrieve a texture just once with glTexImage2D and update it with glTexSubImage2D later.
  // Benefits: glTexSubImage2D is faster and supports non-power-of-two widths/height.
  glBindTexture(GL_TEXTURE_2D, fVideoTex);
  glTexEnvi(GL_TEXTURE_2D, GL_TEXTURE_ENV_MODE, GL_REPLACE);
  glTexImage2D(GL_TEXTURE_2D, 0, 3, TexWidth, TexHeight, 0,
      PIXEL_FMT_OPENGL, GL_UNSIGNED_BYTE, nil);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);


  fVideoOpened := True;

  Result := true;
end;

procedure TVideoPlayback_ffmpeg.Close;
begin
  if fVideoOpened then
  begin
    av_free(FrameBuffer);
    av_free(AVFrameRGB);
    av_free(AVFrame);

    avcodec_close(VideoCodecContext);
    av_close_input_file(VideoFormatContext);

    fVideoOpened := False;
  end;
end;

procedure TVideoPlayback_ffmpeg.Play;
begin
end;

procedure TVideoPlayback_ffmpeg.Pause;
begin
  fVideoPaused := not fVideoPaused;
end;

procedure TVideoPlayback_ffmpeg.Stop;
begin
end;

procedure TVideoPlayback_ffmpeg.SetPosition(Time: real);
var
  SeekFlags: integer;
begin
  if (Time < 0) then
    Time := 0;

  // TODO: handle loop-times
  //Time := Time mod VideoDuration;

  // backward seeking might fail without AVSEEK_FLAG_BACKWARD
  SeekFlags := AVSEEK_FLAG_ANY;
  if (Time < VideoTime) then
    SeekFlags := SeekFlags or AVSEEK_FLAG_BACKWARD;

  VideoTime := Time;
  EOF := false;

  if (av_seek_frame(VideoFormatContext, VideoStreamIndex, Floor(Time/VideoTimeBase), SeekFlags) < 0) then
  begin
    Log.LogError('av_seek_frame() failed', 'TVideoPlayback_ffmpeg.SetPosition');
  end;
end;

function  TVideoPlayback_ffmpeg.GetPosition: real;
begin
  // TODO: return video-position in seconds
  result := VideoTime;
end;

initialization
  singleton_VideoFFMpeg := TVideoPlayback_ffmpeg.create();
  AudioManager.add( singleton_VideoFFMpeg );

finalization
  AudioManager.Remove( singleton_VideoFFMpeg );

end.
