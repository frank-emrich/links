val read : aliases:FrontendTypeEnv.tycon_environment -> string -> Types.datatype

val sentence : FrontendTypeEnv.t -> Sugartypes.sentence -> FrontendTypeEnv.t * Sugartypes.sentence
val program  : FrontendTypeEnv.tycon_environment -> Sugartypes.program -> Sugartypes.program

val all_datatypes_desugared : SugarTraversals.predicate
