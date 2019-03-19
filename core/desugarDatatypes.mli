val read : aliases:Types.FrontendTypeEnv.tycon_environment -> string -> Types.datatype

val sentence : Types.FrontendTypeEnv.t -> Sugartypes.sentence -> Types.FrontendTypeEnv.t * Sugartypes.sentence
val program  : Types.FrontendTypeEnv.tycon_environment -> Sugartypes.program -> Sugartypes.program

val all_datatypes_desugared : SugarTraversals.predicate
