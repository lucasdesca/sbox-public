using System;

namespace Editor.CodeEditors;

[Title( "Custom" )]
[Description( "Manually selected code editor" )]
public class CustomCodeEditor : ICodeEditor
{
	public static string CustomPath
	{
		get => EditorCookie.GetString( "CodeEditor.CustomPath", "" );
		set => EditorCookie.SetString( "CodeEditor.CustomPath", value );
	}

	public void OpenFile( string path, int? line = null, int? column = null )
	{
		var exe = CustomPath;
		if ( string.IsNullOrEmpty( exe ) ) return;

		var startInfo = new System.Diagnostics.ProcessStartInfo
		{
			FileName = exe,
			Arguments = $"\"{path}\"",
			CreateNoWindow = true
		};

		System.Diagnostics.Process.Start( startInfo );
	}

	public void OpenSolution()
	{
		var exe = CustomPath;
		if ( string.IsNullOrEmpty( exe ) ) return;

		var startInfo = new System.Diagnostics.ProcessStartInfo
		{
			FileName = exe,
			Arguments = $"\"{CodeEditor.AddonSolutionPath()}\"",
			CreateNoWindow = true
		};

		System.Diagnostics.Process.Start( startInfo );
	}

	public void OpenAddon( Project addon )
	{
		OpenSolution();
	}

	public bool IsInstalled()
	{
		var path = CustomPath;
		return !string.IsNullOrEmpty( path ) && System.IO.File.Exists( path );
	}
}
