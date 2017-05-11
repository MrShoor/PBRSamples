unit untMain;

interface

uses
  {$IfDef DCC}
  Windows, Messages,
  {$EndIf}
  {$IfDef FPC}
  LCLType, LCLIntf,
  {$EndIf}
  SysUtils, Variants, Classes, Graphics,
  Controls, Forms, Dialogs,
  avRes, avContnrs, avTess, avTypes, avMesh, avModel, avCameraController,
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
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormPaint(Sender: TObject);
    procedure FormKeyPress(Sender: TObject; var Key: Char);
  private
    FMain: TavMainRender;
    FFBO : TavFrameBuffer;

    FProg: TavProgram;

    FCollection: TavModelCollection;

    FModels : IavModelInstanceArr;
    FMaterials : IMaterialArr;
  public
    {$IfDef FPC}
    procedure EraseBackground(DC: HDC); override;
    {$EndIf}
    {$IfDef DCC}
    procedure WMEraseBkgnd(var Message: TWmEraseBkgnd); message WM_ERASEBKGND;
    {$EndIf}
  public
    procedure LoadModel;
    procedure RenderScene;
  end;

var
  frmMain: TfrmMain;

implementation

{$IfnDef FPC}
    {$R *.dfm}
{$Else}
    {$R 'PBRShaders\shaders.rc'}
    {$R *.lfm}
{$EndIf}

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FMain := TavMainRender.Create(nil);
  FMain.Window := Handle;

  FMain.Projection.Fov := 0.25*Pi;

  FMain.Camera.At := Vec(0, 5, 0);
  FMain.Camera.Eye := Vec(0, 5, -15);

  FFBO := Create_FrameBuffer(FMain, [TTextureFormat.RGBA, TTextureFormat.D32f], [true, false]);
  FProg := TavProgram.Create(FMain);
  FProg.Load('PBR', False, 'PBRShaders\!Out');

  FCollection := TavModelCollection.Create(FMain);

  with TavCameraController.Create(FMain) do
  begin
    CanRotate := True;
  end;

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

procedure TfrmMain.FormPaint(Sender: TObject);
begin
  RenderScene;
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
          material.f0 := Vec(61.0, 61.0, 61.0) * (1/255.0);
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

//  avMesh.LoadFromFile('..\Media\Statue\statue.avm', meshes, meshInstances);
//  material.albedo := Vec(0.01, 0.01, 0.01);
//  material.f0 := Vec(255, 219, 145) * (1/255.0);
//  material.roughness := 0.5;
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

    FFBO.FrameRect := RectI(0, 0, FMain.WindowSize.x, FMain.WindowSize.y);
    FFBO.Select();
    FFBO.Clear(0, Vec(0,0,0,0));
    FFBO.ClearDS(FMain.Projection.DepthRange.y);

    FProg.Select();
    FCollection.Select;
    for I := 0 to FModels.Count - 1 do
    begin
      FProg.SetUniform('m_albedo', FMaterials[I].albedo);
      FProg.SetUniform('m_f0', FMaterials[I].f0);
      FProg.SetUniform('m_roughness', FMaterials[I].roughness);
      FCollection.Draw([FModels[I]]);
    end;

    FFBO.BlitToWindow(0);
    FMain.Present;
  finally
    FMain.Unbind;
  end;
end;

end.
