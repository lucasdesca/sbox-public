namespace Editor.MeshEditor;

/// <summary>
/// Build primitives out of polygons.
/// </summary>
public abstract class PrimitiveBuilder
{
	/// <summary>
	/// A list of vertices and faces.
	/// </summary>
	public sealed class PolygonMesh
	{
		/// <summary>
		/// A list of indices indexing into the <see cref="Vertices"/> list.
		/// </summary>
		public sealed class Face
		{
			private readonly int[] _indices;
			public IReadOnlyList<int> Indices => _indices;
			public string Material { get; set; }

			internal Face( IEnumerable<int> indices )
			{
				_indices = indices.ToArray();
			}
		}

		public List<Vector3> Vertices { get; private init; } = new();

		/// <summary>
		/// Per-vertex texture coordinates, kept in sync with <see cref="Vertices"/> by AddVertex. Vertices
		/// added without an explicit UV default to <see cref="Vector2.Zero"/>.
		/// </summary>
		public List<Vector2> TexCoords { get; private init; } = new();

		public List<Face> Faces { get; private init; } = new();

		/// <summary>
		/// Adds a new vertex to the end of the <see cref="Vertices"/> list.
		/// </summary>
		/// <param name="position">Position of the vertex to add.</param>
		/// <returns>The index of the newly added vertex.</returns>
		public int AddVertex( Vector3 position )
		{
			var index = Vertices.FindIndex( x => x.Distance( position ).AlmostEqual( 0.0f ) );
			if ( index >= 0 )
				return index;

			Vertices.Add( position );
			TexCoords.Add( Vector2.Zero );
			return Vertices.Count - 1;
		}

		/// <summary>
		/// Adds a vertex with an explicit texture coordinate, WITHOUT position de-duplication. Use this when
		/// faces need their own per-corner UVs (e.g. imported brush faces with independent texture
		/// projections, where a shared corner can't carry a single UV). The position weld happens later in
		/// ConstructFromData.
		/// </summary>
		/// <param name="position">Position of the vertex to add.</param>
		/// <param name="texCoord">Texture coordinate for this vertex.</param>
		/// <returns>The index of the newly added vertex.</returns>
		public int AddVertex( Vector3 position, Vector2 texCoord )
		{
			Vertices.Add( position );
			TexCoords.Add( texCoord );
			return Vertices.Count - 1;
		}

		/// <summary>
		/// Adds a new face to the end of the <see cref="Faces"/> list.
		/// </summary>
		/// <param name="indices">The vertex indices which define the face, ordered anticlockwise.</param>
		/// <returns>The newly added face.</returns>
		public Face AddFace( params int[] indices )
		{
			if ( indices.Length < 3 )
				return null;

			Faces.Add( new Face( indices ) );
			return Faces[^1];
		}

		/// <summary>
		/// Adds a new face to the end of the <see cref="Faces"/> list and it's vertices to the end of the <see cref="Vertices"/> list.
		/// </summary>
		/// <param name="positions">The vertex positions which define the face, ordered anticlockwise.</param>
		/// <returns>The newly added face.</returns>
		public Face AddFace( params Vector3[] positions )
		{
			if ( positions.Length < 3 )
				return null;

			Faces.Add( new Face( positions.Select( p => AddVertex( p ) ) ) );
			return Faces[^1];
		}

		/// <summary>
		/// Adds a new face with explicit per-corner texture coordinates. Vertices are added without
		/// position de-duplication so each face keeps its own UVs.
		/// </summary>
		/// <param name="positions">The vertex positions which define the face, ordered anticlockwise.</param>
		/// <param name="texCoords">Per-vertex texture coordinates, matching <paramref name="positions"/>.</param>
		/// <returns>The newly added face.</returns>
		public Face AddFace( Vector3[] positions, Vector2[] texCoords )
		{
			if ( positions.Length < 3 )
				return null;

			var indices = new int[positions.Length];
			for ( int i = 0; i < positions.Length; i++ )
				indices[i] = AddVertex( positions[i], i < texCoords.Length ? texCoords[i] : Vector2.Zero );

			Faces.Add( new Face( indices ) );
			return Faces[^1];
		}
	}

	/// <summary>
	/// Create the primitive in the mesh.
	/// </summary>
	public abstract void Build( PolygonMesh mesh );

	/// <summary>
	/// Setup properties from box.
	/// </summary>
	public abstract void SetFromBox( BBox box );

	/// <summary>
	/// If this primitive is 2D the bounds box will be limited to have no depth.
	/// </summary>
	[Hide]
	public virtual bool Is2D { get => false; }

	/// <summary>
	/// The material to use for this whole primitive. Loaded on demand so builders can be
	/// created without the render system.
	/// </summary>
	[Hide]
	public Material Material
	{
		get => field ??= Material.Load( "materials/dev/reflectivity_30.vmat" );
		set;
	}
}
