unit untMain;

interface

uses
  {$IfnDef FPC}
  Windows, Messages, AppEvnts,
  {$EndIf}
  {$IfDef FPC}
  LCLType, LCLIntf,
  {$EndIf}
  SysUtils, Variants, Classes, Graphics,
  Generics.Collections, Generics.Defaults,
  Controls, Forms, Dialogs,
  avRes, avContnrs, avTess, avTypes, avMesh, avModel, avCameraController, avTexLoader, avUtils,
  mutils;

type
  TMaterial = packed record
    albedo    : TVec3;
    f0        : TVec3;
    roughness : Single;
  end;
  IMaterialArr = {$IfDef FPC}specialize{$EndIf}IArray<TMaterial>;
  TMaterialArr = {$IfDef FPC}specialize{$EndIf}TArray<TMaterial>;

  { TfrmMain }

  TfrmMain = class(TForm)
    {$IfDef DCC}
    ApplicationEvents: TApplicationEvents;
    {$EndIf}
    {$IfDef FPC}
    ApplicationProperties1: TApplicationProperties;
    {$EndIf}
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormPaint(Sender: TObject);
    procedure FormKeyPress(Sender: TObject; var Key: Char);
    procedure ApplicationIdle(Sender: TObject; var Done: Boolean);
  private
    FMain: TavMainRender;
    FFBO : TavFrameBuffer;
    FFBO_Resolved : TavFrameBuffer;

    FProg: TavProgram;
    FProgResolve: TavProgram;

    FCollection: TavModelCollection;

    FModels : IavModelInstanceArr;
    FMaterials : IMaterialArr;

    FIrradiance: TavTexture;
    FRadiance : TavTexture;
    FHammersleyPts: TVec4Arr;

    FQuad: TavVB;

    FLastCameraUpdateID: Integer;
    FLastProjectionUpdateID: Integer;
  public
    {$IfDef FPC}
    procedure EraseBackground(DC: HDC); override;
    {$EndIf}
    {$IfDef DCC}
    procedure WMEraseBkgnd(var Message: TWmEraseBkgnd); message WM_ERASEBKGND;
    {$EndIf}
  public
    function GenerateRandomSamples(const ACount: Integer): TVec4Arr;
    procedure LoadEnviromentMap;
    procedure LoadModel;
    procedure RenderScene;
  end;

var
  frmMain: TfrmMain;

implementation

uses Math;

{$IfnDef FPC}
    {$R *.dfm}
{$Else}
    {$R 'PBRShaders\shaders.rc'}
    {$R *.lfm}
{$EndIf}

function RandomRay(): TVec3;
var theta, cosphi, sinphi: Single;
begin
  theta := 2 * Pi * Random;
  cosphi := 1 - 2 * Random;
  sinphi := sqrt(1 - min(1.0, sqr(cosphi)));
  Result.x := sinphi * cos(theta);
  Result.y := sinphi * sin(theta);
  Result.z := cosphi;
end;

function HammersleyPoint(const I, N: Integer): TVec2;
  function radicalInverse_VdC(bits: Cardinal): Single;
  begin
    bits := (bits shl 16) or (bits shr 16);
    bits := ((bits and $55555555) shl 1) or ((bits and $AAAAAAAA) shr 1);
    bits := ((bits and $33333333) shl 2) or ((bits and $CCCCCCCC) shr 2);
    bits := ((bits and $0F0F0F0F) shl 4) or ((bits and $F0F0F0F0) shr 4);
    bits := ((bits and $00FF00FF) shl 8) or ((bits and $FF00FF00) shr 8);
    Result := bits * 2.3283064365386963e-10;
  end;
begin
  Result.x := I/N;
  Result.y := radicalInverse_VdC(I);
end;

function GenerateHammersleyPts(const N: Integer): TVec4Arr;
var E: TVec2;
    I: Integer;
    offset: TVec2;
begin
  offset.x := Random/N;
  offset.y := Random/N;

  SetLength(Result, N);
  for I := 0 to N-1 do
  begin
    E := HammersleyPoint(I, N);
    //E := E + offset;
    if E.x > 1.0 then
      E.x := E.x - 1.0;
    if E.y > 1.0 then
      E.y := E.y - 1.0;
    Result[i].xy := E;
    Result[i].z := 0;
    Result[i].w := 0;
  end;
//    TArray.Sort<TVec4>(Result,
//      TDelegatedComparer<TVec4>.Create(
//        function (const Left, Right: TVec4): Integer
//        begin
//          Result := -sign(Right.y - Left.y);
//        end
//      )
//    );
end;

procedure TfrmMain.ApplicationIdle(Sender: TObject; var Done: Boolean);
begin
  Done := False;
  if FMain <> nil then
      FMain.InvalidateWindow;
end;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FMain := TavMainRender.Create(nil);
  FMain.Window := Handle;

  FMain.Projection.Fov := 0.25*Pi;

  FMain.Camera.At := Vec(0, 5, 0);
  FMain.Camera.Eye := Vec(0, 5, -15);

  FFBO := Create_FrameBuffer(FMain, [TTextureFormat.RGBA32f, TTextureFormat.D32f], [false, false]);
  FFBO_Resolved := Create_FrameBuffer(FMain, [TTextureFormat.RGBA], [true]);

  FProg := TavProgram.Create(FMain);
  FProg.Load('PBR', False, 'PBRShaders\!Out');

  FProgResolve := TavProgram.Create(FMain);
  FProgResolve.Load('PBR_Resolve', False, 'PBRShaders\!Out');

  FQuad := GenQuad_VB(FMain, Vec(-1,-1,1,1));

  FCollection := TavModelCollection.Create(FMain);

  with TavCameraController.Create(FMain) do
  begin
    CanRotate := True;
  end;

  LoadEnviromentMap;
  LoadModel;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  FreeAndNil(FMain);
end;

procedure TfrmMain.FormKeyPress(Sender: TObject; var Key: Char);
begin
  FProg.Invalidate;
  FMain.InvalidateWindow;
end;

{$IfDef FPC}
procedure TfrmMain.EraseBackground(DC: HDC);
begin
end;
{$EndIf}

{$IfDef DCC}
procedure TfrmMain.WMEraseBkgnd(var Message: TWmEraseBkgnd);
begin
    Message.Result := 1;
end;
{$EndIf}

procedure TfrmMain.LoadEnviromentMap;
begin
  FIrradiance := TavTexture.Create(FMain);
  FIrradiance.TexData := LoadTexture('irradiance.dds');
  FIrradiance.TargetFormat := TTextureFormat.RGBA16f;
  FIrradiance.AutoGenerateMips := True;

  FRadiance := TavTexture.Create(FMain);
  FRadiance.TexData := LoadTexture('radiance.dds');
  //FRadiance.TexData := LoadTexture('snow.dds');
  FRadiance.TargetFormat := TTextureFormat.RGBA16f;
  //FRadiance.TargetFormat := TTextureFormat.DXT3;
  FRadiance.sRGB := True;
end;

procedure TfrmMain.FormPaint(Sender: TObject);
begin
  RenderScene;
end;

function TfrmMain.GenerateRandomSamples(const ACount: Integer): TVec4Arr;
var i: Integer;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do
    Result[i] := Vec(Random, Random, Random, Random);
end;

procedure TfrmMain.LoadModel;
var meshes: IavMeshes;
    meshInstances: IavMeshInstances;
    tmpInstances : IavMeshInstanceArray;
    tmpInstance : IavMeshInstance;
    material: TMaterial;
    x, y: Integer;
begin
  FMaterials := TMaterialArr.Create;

  avMesh.LoadFromFile('sphere.avm', meshes, meshInstances);

  //clone to several meshes and assign different materials
  tmpInstances := TavMeshInstanceArray.Create;
  for y := -1 to 1 do
  begin
    case y of
      -1:
        begin
          material.albedo := Vec(0.01, 0.01, 0.01);
          material.f0 := Vec(255.0, 219.0, 145.0) * (1/255.0);
        end;
      0 :
        begin
          material.albedo := Vec(220.0, 45.0, 0.0) * (1/255.0);
          material.f0 := Vec(41.0, 41.0, 41.0) * (1/255.0);
        end;
    else
      material.albedo := Vec(120.0, 200.0, 186.0) * (1/255.0);
      material.f0 := Vec(10.0, 10.0, 10.0) * (1/255.0);
    end;
    for x := -3 to 3 do
    begin
      tmpInstance := meshInstances['Icosphere'].Clone('Icosphere: ' + IntToStr(x) + '_' + IntToStr(y));
      tmpInstance.Transform := MatTranslate(Vec(x, y+5/3, 0)*3);

      material.roughness := clamp((x+3)/6, 0.05, 1.0);
      FMaterials.Add(material);
      tmpInstances.Add( tmpInstance );
    end;
  end;
  FModels := FCollection.AddFromMeshInstances(tmpInstances);

//  avMesh.LoadFromFile('statue.avm', meshes, meshInstances);
//  material.albedo := Vec(0.01, 0.01, 0.01);
//  material.f0 := Vec(255, 219, 145) * (1/255.0);
//  material.roughness := 0.25;
//  for x := 0 to meshInstances.Count - 1 do
//    FMaterials.Add(material);
//  FModels := FCollection.AddFromMeshInstances(meshInstances);
end;

procedure TfrmMain.RenderScene;
var I : Integer;
begin
  if FMain = nil then Exit;
  if not FMain.Inited3D then
    FMain.Init3D(T3DAPI.apiDX11);
  if not FMain.Inited3D then Exit;

  FMain.Bind;
  try
    FMain.States.DepthTest := True;

    //generate random samples
    //if FHammersleyPts = nil then
      FHammersleyPts := GenerateHammersleyPts(16);
      //FHammersleyPts := GenerateHammersleyPts(1);
      //FHammersleyPts := GenerateHammersleyPts(1024);
    //FHammersleyPts := GenerateRandomSamples(1024);

    //cumulative render
    FMain.States.Blending[0] := True;
    FMain.States.SetBlendFunctions(bfOne, bfOne);

    FFBO.FrameRect := RectI(0, 0, FMain.WindowSize.x, FMain.WindowSize.y);
    FFBO.Select();
    if (FLastCameraUpdateID <> FMain.Camera.UpdateID) or (FLastProjectionUpdateID <> FMain.Projection.UpdateID) then
    begin
      FLastCameraUpdateID := FMain.Camera.UpdateID;
      FLastProjectionUpdateID := FMain.Projection.UpdateID;
      FFBO.Clear(0, Vec(0,0,0,0));
    end;

    FFBO.ClearDS(FMain.Projection.DepthRange.y);

    FProg.Select();
    FCollection.Select;
    //depth prepass
    FMain.States.ColorMask[0] := [];
    for I := 0 to FModels.Count - 1 do
    begin
      FProg.SetUniform('m_albedo', FMaterials[I].albedo);
      FProg.SetUniform('m_f0', FMaterials[I].f0);
      FProg.SetUniform('m_roughness', FMaterials[I].roughness);
      FProg.SetUniform('uHammersleyPts', FHammersleyPts);
      FProg.SetUniform('uSamplesCount', Length(FHammersleyPts)*1.0);
      FProg.SetUniform('uIrradiance', FIrradiance, Sampler_Linear);
      FProg.SetUniform('uRadiance', FRadiance, Sampler_Linear);
      FCollection.Draw([FModels[I]]);
    end;
    FMain.States.ColorMask[0] := [cmRed, cmGreen, cmBlue, cmAlpha];
    //render to color
    FMain.States.DepthFunc := cfEqual;
    for I := 0 to FModels.Count - 1 do
    begin
      FProg.SetUniform('m_albedo', FMaterials[I].albedo);
      FProg.SetUniform('m_f0', FMaterials[I].f0);
      FProg.SetUniform('m_roughness', FMaterials[I].roughness);
      FProg.SetUniform('uHammersleyPts', FHammersleyPts);
      FProg.SetUniform('uSamplesCount', Length(FHammersleyPts)*1.0);
      FProg.SetUniform('uIrradiance', FIrradiance, Sampler_Linear);
      FProg.SetUniform('uRadiance', FRadiance, Sampler_Linear);
      FCollection.Draw([FModels[I]]);
    end;
    FMain.States.DepthFunc := cfLess;

    //resolve accum buffer
    FMain.States.Blending[0] := False;

    FFBO_Resolved.FrameRect := RectI(0, 0, FMain.WindowSize.x, FMain.WindowSize.y);
    FFBO_Resolved.Select();

    FProgResolve.Select();
    FProgResolve.SetAttributes(FQuad, nil, nil);
    FProgResolve.SetUniform('uColor', FFBO.GetColor(0), Sampler_Linear);
    FProgResolve.Draw();

    FFBO_Resolved.BlitToWindow(0);
    FMain.Present;
  finally
    FMain.Unbind;
  end;
end;

end.
