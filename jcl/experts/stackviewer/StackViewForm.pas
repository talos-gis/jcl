unit StackViewForm;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, Docktoolform, StdCtrls, ComCtrls, Menus,
  PlatformDefaultStyleActnCtrls, ActnPopup, ActnList, ToolWin, ExtCtrls, ToolsAPI,
  JclDebug, JclDebugStackUtils, Contnrs, StackFrame, ModuleFrame,
  StackViewUnit, StackFrame2, StackCodeUtils, ExceptInfoFrame, ThreadFrame, ExceptionViewerOptionsUnit,
  StackLineNumberTranslator, JclOtaUtils
  , ActiveX
  , FileSearcherUnit, JclStrings
  ;

type
  TfrmStackView = class(TDockableToolbarForm)
    ActionList1: TActionList;
    acJumpToCodeLine: TAction;
    ToolButton1: TToolButton;
    PopupActionBar1: TPopupActionBar;
    mnuJumpToCodeLine: TMenuItem;
    N1: TMenuItem;
    StayonTop2: TMenuItem;
    Dockable2: TMenuItem;
    acLoadStack: TAction;
    ToolButton2: TToolButton;
    ToolButton3: TToolButton;
    OpenDialog1: TOpenDialog;
    cboxThread: TComboBox;
    tv: TTreeView;
    acOptions: TAction;
    ToolButton4: TToolButton;
    ToolButton5: TToolButton;
    acUpdateLocalInfo: TAction;
    ToolButton6: TToolButton;
    ToolButton7: TToolButton;
    Splitter2: TSplitter;
    procedure FormCreate(Sender: TObject);
    procedure acJumpToCodeLineExecute(Sender: TObject);
    procedure acLoadStackExecute(Sender: TObject);
    procedure cboxThreadChange(Sender: TObject);
    procedure tvChange(Sender: TObject; Node: TTreeNode);
    procedure acOptionsExecute(Sender: TObject);
    procedure acUpdateLocalInfoExecute(Sender: TObject);
  private
    { Private declarations }
    FStackItemList: TStackViewItemsList;
    FCreationStackItemList: TStackViewItemsList;
    FTreeViewLinkList: TObjectList;
    FThreadInfoList: TThreadInfoList;
    FExceptionInfo: TExceptionInfo;
    FStackFrame: TfrmStack;
    FModuleFrame: TfrmModule;
    FExceptionFrame: TfrmException;
    FThreadFrame: TfrmThread;
    FLastControl: TControl;
    FOptions: TExceptionViewerOption;
    FRootDir: string;
    procedure PrepareStack(AStack: TJclLocationInfoList; AStackItemList: TStackViewItemsList);
    procedure SetOptions(const Value: TExceptionViewerOption);
  public
    { Public declarations }
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property Options: TExceptionViewerOption read FOptions write SetOptions;
    property RootDir: string read FRootDir write FRootDir;
  end;

var
  frmStackView: TfrmStackView;

implementation

const
  IDEDesktopIniSection = 'TStackViewAddIn';//todo - move

{$R *.dfm}

type
  TTreeViewLinkKind = (tvlkException, tvlkModuleList, tvlkThread, tvlkThreadStack, tvlkThreadCreationStack);

  TTreeViewLink = class(TObject)
  private
    FData: TObject;
    FKind: TTreeViewLinkKind;
  public
    property Data: TObject read FData write FData;
    property Kind: TTreeViewLinkKind read FKind write FKind;
  end;

{ TfrmStackView }

procedure TfrmStackView.FormCreate(Sender: TObject);
begin
  inherited;
  DeskSection := IDEDesktopIniSection;
  AutoSave := True;
end;

type
  TFindMapping = class(TObject)
  private
    FItems: TList;
    function GetCount: Integer;
    function GetItems(AIndex: Integer): TStackViewItem;
  public
    FoundFile: Boolean;
    FileName: string;
    ProjectName: string;
    constructor Create;
    destructor Destroy; override;
    procedure Add(AStackViewItem: TStackViewItem);
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TStackViewItem read GetItems; default;
  end;

constructor TFindMapping.Create;
begin
  inherited Create;
  FItems := TList.Create;
end;

destructor TFindMapping.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TFindMapping.Add(AStackViewItem: TStackViewItem);
begin
  FItems.Add(AStackViewItem);
end;

function TFindMapping.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TFindMapping.GetItems(AIndex: Integer): TStackViewItem;
begin
  Result := FItems[AIndex];
end;

function GetFileEditorContent(const AFileName: string): IStream;
var
  I: Integer;
  Module: IOTAModule;
  EditorContent: IOTAEditorContent;
begin
  Result := nil;
  Module := (BorlandIDEServices as IOTAModuleServices).FindModule(AFileName);
  if Assigned(Module) then
  begin
    for I := 0 to Module.ModuleFileCount - 1 do
      if Supports(Module.ModuleFileEditors[I], IOTAEditorContent, EditorContent) then
      begin
        Result := EditorContent.Content;
        Break;
      end;
  end;
end;

procedure TfrmStackView.PrepareStack(AStack: TJclLocationInfoList; AStackItemList: TStackViewItemsList);
var
  I, J, K, Idx, NewLineNumber: Integer;
  StackViewItem: TStackViewItem;
  FindFileList: TStringList;
  FindMapping: TFindMapping;
  FileName, ProjectName: string;
  RevisionMS: TMemoryStream;
  RevisionStream, Stream: IStream;
  FS: TFileStream;

  S: string;
  EV: IOTAEnvironmentOptions;
  FileSearcher: TFileSearcher;
  BrowsingPaths: TStringList;

  Found: Boolean;
  RevisionLineNumbers, CurrentLineNumbers: TList;
begin
  AStackItemList.Clear;
  if AStack.Count > 0 then
  begin
    FindFileList := TStringList.Create;
    try
      FindFileList.Sorted := True;
      //check if the files can be found in a project in the current project group
      for I := 0 to AStack.Count - 1 do
      begin
        StackViewItem := AStackItemList.Add;
        StackViewItem.Assign(AStack[I]);
        Idx := FindFileList.IndexOf(AStack[I].SourceName);
        if Idx <> -1 then
        begin
          FindMapping := TFindMapping(FindFileList.Objects[Idx]);
          FindMapping.Add(StackViewItem);
          StackViewItem.FoundFile := FindMapping.FoundFile;
          StackViewItem.FileName := FindMapping.FileName;
          StackViewItem.ProjectName := FindMapping.ProjectName;
        end
        else
        begin
          if AStack[I].SourceName <> '' then
            FileName := FindModuleAndProject(AStack[I].SourceName, ProjectName)
          else
          begin
            FileName := '';
            ProjectName := '';
          end;
          FindMapping := TFindMapping.Create;
          FindMapping.Add(StackViewItem);
          FindFileList.AddObject(AStack[I].SourceName, FindMapping);
          FindMapping.FoundFile := FileName <> '';
          FindMapping.FileName := FileName;
          FindMapping.ProjectName := ProjectName;

          StackViewItem.FoundFile := FileName <> '';
          StackViewItem.FileName := FileName;
          StackViewItem.ProjectName := ProjectName;
        end;
      end;

      //check if the other files can be found in BrowsingPath
      Found := False;
      for I := 0 to FindFileList.Count - 1 do
      begin
        FindMapping := TFindMapping(FindFileList.Objects[I]);
        if (FindFileList[I] <> '') and (not FindMapping.FoundFile) then
        begin
          Found := True;
          Break;
        end;
      end;
      if Found then
      begin
        FileSearcher := TFileSearcher.Create;
        try
          BrowsingPaths := TStringList.Create;
          try
            EV := (BorlandIDEServices as IOTAServices).GetEnvironmentOptions;
            StrTokenToStrings(EV.Values['BrowsingPath'], ';', BrowsingPaths);
            for I := 0 to BrowsingPaths.Count - 1 do
            begin
              S := BrowsingPaths[I];
              if Pos('$(BDS)', S) > 0 then
                S := StringReplace(S, '$(BDS)', RootDir, []);
              FileSearcher.SearchPaths.Add(S);
            end;
          finally
            BrowsingPaths.Free;
          end;
          if FileSearcher.SearchPaths.Count > 0 then
          begin
            for I := 0 to FindFileList.Count - 1 do
            begin
              FindMapping := TFindMapping(FindFileList.Objects[I]);
              if (FindFileList[I] <> '') and (not FindMapping.FoundFile) and (FileSearcher.IndexOf(FindFileList[I]) = -1) then
                FileSearcher.Add(FindFileList[I]);
            end;
            if FileSearcher.Count > 0 then
            begin
              FileSearcher.Search;
              for I := 0 to FindFileList.Count - 1 do
              begin
                FindMapping := TFindMapping(FindFileList.Objects[I]);
                if not FindMapping.FoundFile then
                begin
                  Idx := FileSearcher.IndexOf(FindFileList[I]);
                  if (Idx <> -1) and (FileSearcher[Idx].Results.Count > 0) then
                  begin
                    FindMapping.FoundFile := True;
                    FindMapping.FileName := FileSearcher[Idx].Results[0];
                    FindMapping.ProjectName := '';
                    for J := 0 to FindMapping.Count - 1 do
                    begin
                      FindMapping[J].FoundFile := FindMapping.FoundFile;
                      FindMapping[J].FileName := FindMapping.FileName;
                      FindMapping[J].ProjectName := FindMapping.ProjectName;
                    end;
                  end;
                end;
              end;
            end;
          end;
        finally
          FileSearcher.Free;
        end;
      end;
      for I := 0 to FindFileList.Count - 1 do
      begin
        FindMapping := TFindMapping(FindFileList.Objects[I]);
        if (FindMapping.FoundFile) and (FindMapping.Count > 0) {and (FindMapping[0].Revision <> '')} then//todo - check revision
        begin
          Found := False;
          for J := 0 to FindMapping.Count - 1 do
            if FindMapping[J].LineNumber > 0 then
            begin
              Found := True;
              Break;
            end;
          if Found then
          begin
            Stream := GetFileEditorContent(FindMapping.FileName);
            if not Assigned(Stream) then
            begin
              if FileExists(FindMapping.FileName) then
              begin
(BorlandIDEServices as IOTAMessageServices).AddTitleMessage(Format('Using %s', [FindMapping.FileName]));//todo - remove
                FS := TFileStream.Create(FindMapping.FileName, fmOpenRead);
                Stream := TStreamAdapter.Create(FS);
              end;
            end
            else
              FS := nil;
            try
              if Assigned(Stream) and (FS = nil) then//todo - remove FS = nil
              begin
                RevisionLineNumbers := TList.Create;
                CurrentLineNumbers := TList.Create;
                try
                  for J := 0 to FindMapping.Count - 1 do
                    if FindMapping[J].LineNumber > 0 then
                      RevisionLineNumbers.Add(Pointer(FindMapping[J].LineNumber));
                  RevisionMS := TMemoryStream.Create;
                  try
                    RevisionStream := TStreamAdapter.Create(RevisionMS);
(BorlandIDEServices as IOTAMessageServices).AddTitleMessage(Format('F1 %s', [FindMapping.FileName]));//todo - remove
                    if GetRevisionContent(FindMapping.FileName, FindMapping[0].Revision, RevisionStream) then
                    begin
(BorlandIDEServices as IOTAMessageServices).AddTitleMessage(Format('F2 %s', [FindMapping.FileName]));//todo - remove
                      if TranslateLineNumbers(RevisionStream, Stream, RevisionLineNumbers, CurrentLineNumbers) > 0 then
                      begin
(BorlandIDEServices as IOTAMessageServices).AddTitleMessage(Format('F3 %s', [FindMapping.FileName]));//todo - remove
                        if RevisionLineNumbers.Count = CurrentLineNumbers.Count then
                        begin
                          for J := 0 to FindMapping.Count - 1 do
                            if FindMapping[J].LineNumber > 0 then
                            begin
                              FindMapping[J].TranslatedLineNumber := -1;
                              for K := 0 to RevisionLineNumbers.Count - 1 do
                                if Integer(RevisionLineNumbers[K]) = FindMapping[J].LineNumber then
                                begin
                                  FindMapping[J].TranslatedLineNumber := Integer(CurrentLineNumbers[K]);
                                  Break;
                                end;
                            end;
                        end;
                      end;
                    end;
                  finally
                    RevisionMS.Free;
                  end;
                finally
                  RevisionLineNumbers.Free;
                  CurrentLineNumbers.Free;
                end;
              end;
            finally
              FS.Free;
            end;
            StackViewItem.TranslatedLineNumber := NewLineNumber;
          end;
        end;
      end;
    finally
      for I := 0 to FindFileList.Count - 1 do
        FindFileList.Objects[I].Free;
      FindFileList.Free;
    end;
  end;
end;

procedure TfrmStackView.SetOptions(const Value: TExceptionViewerOption);
begin
  FOptions.Assign(Value);
end;

procedure TfrmStackView.tvChange(Sender: TObject; Node: TTreeNode);
var
  TreeViewLink: TTreeViewLink;
  NewControl: TControl;
  ThreadInfo: TJclThreadInfo;
begin
  inherited;
  NewControl := nil;
  if Assigned(tv.Selected) and Assigned(tv.Selected.Data) and
    (TObject(tv.Selected.Data) is TTreeViewLink) then
  begin
    TreeViewLink := TTreeViewLink(tv.Selected.Data);
    if (TreeViewLink.Kind = tvlkModuleList) and (TreeViewLink.Data is TModuleList) then
    begin
      NewControl := FModuleFrame;
      FModuleFrame.ModuleList := TModuleList(TreeViewLink.Data);
    end
    else
    if (TreeViewLink.Kind = tvlkThread) and (TreeViewLink.Data is TJclThreadInfo) then
    begin
      ThreadInfo := TJclThreadInfo(TreeViewLink.Data);
      NewControl := FThreadFrame;
      PrepareStack(ThreadInfo.CreationStack, FCreationStackItemList);
      if tioCreationStack in ThreadInfo.Values then
        FThreadFrame.CreationStackList := FCreationStackItemList
      else
        FThreadFrame.CreationStackList := nil;
      if TreeViewLink.Data = FThreadInfoList[0] then
        FThreadFrame.Exception := FExceptionInfo.Exception
      else
        FThreadFrame.Exception := nil;
      PrepareStack(ThreadInfo.Stack, FStackItemList);
      if tioStack in ThreadInfo.Values then
        FThreadFrame.StackList := FStackItemList
      else
        FThreadFrame.StackList := nil;
    end
    else
    if (TreeViewLink.Kind = tvlkException) and (TreeViewLink.Data is TException) then
    begin
      NewControl := FExceptionFrame;
      FExceptionFrame.Exception := TException(TreeViewLink.Data);
    end
    else
    if (TreeViewLink.Kind in [tvlkThreadStack, tvlkThreadCreationStack]) and (TreeViewLink.Data is TJclLocationInfoList) then
    begin
      PrepareStack(TJclLocationInfoList(TreeViewLink.Data), FStackItemList);
      FStackFrame.StackList := FStackItemList;
      NewControl := FStackFrame;
    end;
  end;
  if Assigned(NewControl) then
    NewControl.Show;
  if Assigned(FLastControl) and (FLastControl <> NewControl) then
    FLastControl.Hide;
  if FLastControl <> NewControl then
    FLastControl := NewControl;
end;

procedure TfrmStackView.acJumpToCodeLineExecute(Sender: TObject);
begin
  if Assigned(FThreadFrame) and FThreadFrame.Visible and Assigned(FThreadFrame.Selected) then
    JumpToCode(FThreadFrame.Selected)
  else
  if Assigned(FStackFrame) and FStackFrame.Visible and Assigned(FStackFrame.Selected) then
    JumpToCode(FStackFrame.Selected);
end;

constructor TfrmStackView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
//  FThreadInfoList := TThreadInfoList.Create;
  FExceptionInfo := TExceptionInfo.Create;
  FThreadInfoList := FExceptionInfo.ThreadInfoList;
  FStackItemList := TStackViewItemsList.Create;
  FCreationStackItemList := TStackViewItemsList.Create;
  FTreeViewLinkList := TObjectList.Create;
  FStackFrame := TfrmStack.Create(Self);
  FStackFrame.Name := 'StackFrameSingle';
  FStackFrame.Parent := Self;
  FStackFrame.Align := alClient;
  FStackFrame.Visible := False;

  FModuleFrame := TfrmModule.Create(Self);
  FModuleFrame.Parent := Self;
  FModuleFrame.Align := alClient;
  FModuleFrame.Visible := False;

  FExceptionFrame := TfrmException.Create(Self);
  FExceptionFrame.Name := 'ExceptionFrameSingle';
  FExceptionFrame.Parent := Self;
  FExceptionFrame.Align := alClient;
  FExceptionFrame.Visible := False;

  FThreadFrame := TfrmThread.Create(Self);
  FThreadFrame.Parent := Self;
  FThreadFrame.Align := alClient;
  FThreadFrame.Visible := False;

  FOptions := TExceptionViewerOption.Create;

  FLastControl := nil;
end;

destructor TfrmStackView.Destroy;
begin
  FOptions.Free;
  FTreeViewLinkList.Free;
  FStackItemList.Free;
  FCreationStackItemList.Free;
//  FThreadInfoList.Free;
  FExceptionInfo.Free;
  inherited Destroy;
end;

procedure TfrmStackView.acLoadStackExecute(Sender: TObject);
var
  SS: TStringStream;
  I: Integer;
  S: string;
  tn, tns: TTreeNode;
  TreeViewLink: TTreeViewLink;
begin
  inherited;
  if OpenDialog1.Execute then
  begin
    FStackFrame.StackList := nil;
    FStackItemList.Clear;
    FCreationStackItemList.Clear;
    cboxThread.Items.Clear;
    tv.Items.Clear;
    FTreeViewLinkList.Clear;
    SS := TStringStream.Create;
    try
      SS.LoadFromFile(OpenDialog1.FileName);
      FExceptionInfo.LoadFromString(SS.DataString);

      FTreeViewLinkList.Add(TTreeViewLink.Create);
      TreeViewLink := TTreeViewLink(FTreeViewLinkList.Last);
      TreeViewLink.Kind := tvlkModuleList;
      TreeViewLink.Data := FExceptionInfo.Modules;
      tn := tv.Items.Add(nil, Format('Module List [%d]', [FExceptionInfo.Modules.Count]));
      tn.Data := TreeViewLink;

      if FThreadInfoList.Count > 0 then
      begin
        {
        for I := 0 to FThreadInfoList.Count - 1 do
          cboxThread.Items.AddObject(Format('[%d/%d] ThreadID: %d [%d]', [I + 1, FThreadInfoList.Count,
            FThreadInfoList[I].ThreadID, FThreadInfoList[I].Stack.Count]), FThreadInfoList[I]);
        }
        for I := 0 to FThreadInfoList.Count - 1 do
        begin
          cboxThread.Items.AddObject(Format('[%d/%d] %s', [I + 1, FThreadInfoList.Count, FThreadInfoList[I].AsString]), FThreadInfoList[I]);
          if tioIsMainThread in FThreadInfoList[I].Values then
            S := '[MainThread]'
          else
            S := '';
          S := Format('ID: %d %s', [FThreadInfoList[I].ThreadID, S]);

          FTreeViewLinkList.Add(TTreeViewLink.Create);
          TreeViewLink := TTreeViewLink(FTreeViewLinkList.Last);
          TreeViewLink.Kind := tvlkThread;
          TreeViewLink.Data := FThreadInfoList[I];
          tn := tv.Items.Add(nil, S);
          tn.Data := TreeViewLink;

          if I = 0 then
          begin
            FTreeViewLinkList.Add(TTreeViewLink.Create);
            TreeViewLink := TTreeViewLink(FTreeViewLinkList.Last);
            TreeViewLink.Kind := tvlkException;
            TreeViewLink.Data := FExceptionInfo.Exception;
            tns := tv.Items.AddChild(tn, 'Exception');
            tns.Data := TreeViewLink;
          end;

          if tioStack in FThreadInfoList[I].Values then
          begin
            FTreeViewLinkList.Add(TTreeViewLink.Create);
            TreeViewLink := TTreeViewLink(FTreeViewLinkList.Last);
            TreeViewLink.Kind := tvlkThreadStack;
            TreeViewLink.Data := FThreadInfoList[I].Stack;
            tns := tv.Items.AddChild(tn, Format('Stack [%d]', [FThreadInfoList[I].Stack.Count]));
            tns.Data := TreeViewLink;
          end;

          if tioCreationStack  in FThreadInfoList[I].Values then
          begin
            FTreeViewLinkList.Add(TTreeViewLink.Create);
            TreeViewLink := TTreeViewLink(FTreeViewLinkList.Last);
            TreeViewLink.Kind := tvlkThreadCreationStack;
            TreeViewLink.Data := FThreadInfoList[I].CreationStack;
            tns := tv.Items.AddChild(tn, Format('CreationStack [%d]', [FThreadInfoList[I].CreationStack.Count]));
            tns.Data := TreeViewLink;
          end;
          if FOptions.ExpandTreeView then
            tn.Expanded := True;
        end;

        cboxThread.ItemIndex := 0;
        cboxThreadChange(nil);
      end;
    finally
      SS.Free;
    end;
  end;
end;

procedure TfrmStackView.acOptionsExecute(Sender: TObject);
begin
  inherited;
  TJclOTAExpertBase.ConfigurationDialog('Stack Trace Viewer');
  {
  if ShowOptions(FOptions) then
  begin
  //todo options changed
  end;
  }
end;

procedure TfrmStackView.acUpdateLocalInfoExecute(Sender: TObject);
begin
  inherited;
  tvChange(nil, nil);
end;

procedure TfrmStackView.cboxThreadChange(Sender: TObject);
begin
  inherited;
  {//todo
  if (cboxThread.ItemIndex <> -1) and (cboxThread.Items.Objects[cboxThread.ItemIndex] is TJclThreadInfo) then
    StackListToListBox(TJclThreadInfo(cboxThread.Items.Objects[cboxThread.ItemIndex]).Stack)
  else
  begin
    lbStack.Items.Clear;
    FStackItemList.Clear;
  end;
  }
end;

end.