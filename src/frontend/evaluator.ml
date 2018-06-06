
module Types = Types_
open MyUtil
open LengthInterface
open Types
open EvalUtil

exception EvalError of string

type nom_input_horz_element =
  | NomInputHorzText     of string
  | NomInputHorzEmbedded of abstract_tree * abstract_tree list
  | NomInputHorzContent  of nom_input_horz_element list * environment


let lex_horz_text (ctx : HorzBox.context_main) (s_utf8 : string) : HorzBox.horz_box list =
  let uchlst = InternalText.to_uchar_list (InternalText.of_utf8 s_utf8) in
    HorzBox.([HorzPure(PHCInnerString(ctx, uchlst))])


let interpret_list interpretf (env : environment) getf (ast : abstract_tree) =
  let value = interpretf env ast in
    get_list getf value


let interpret_option interpretf (env : environment) (getf : syntactic_value -> 'a) (ast : abstract_tree) : 'a option =
  let value = interpretf env ast in
    get_option getf value


let rec reduce_beta envf evid valuel astdef =
  let envnew = add_to_environment envf evid (ref valuel) in
    interpret envnew astdef


and reduce_beta_list valuef valuearglst =
  match valuearglst with
  | [] ->
      valuef

  | valuearg :: astargtail ->
      begin
        match valuef with
        | FuncWithEnvironment(patbrs, envf) ->
            let valuefnew = select_pattern (Range.dummy "reduce_beta_list") envf valuearg patbrs in
              reduce_beta_list valuefnew astargtail

        | _ -> report_bug_value "reduce_beta_list" valuef
      end


and interpret_vert env ast =
  let value = interpret env ast in
    get_vert value


and interpret_horz env ast =
  let value = interpret env ast in
    get_horz value


and interpret_point env ast =
  let value = interpret env ast in
    get_point value


and interpret_prepath env ast =
  let value = interpret env ast in
    get_prepath value


and interpret_paddings env ast =
  let value = interpret env ast in
    get_paddings value


and interpret_decoset env ast =
  let value = interpret env ast in
    get_decoset value


and interpret_path env pathcomplst cycleopt =
  let pathelemlst =
    pathcomplst |> List.map (function
      | PathLineTo(astpt) ->
          let pt = interpret_point env astpt in
            GraphicData.LineTo(pt)

      | PathCubicBezierTo(astpt1, astpt2, astpt) ->
          let pt1 = interpret_point env astpt1 in
          let pt2 = interpret_point env astpt2 in
          let pt = interpret_point env astpt in
            GraphicData.CubicBezierTo(pt1, pt2, pt)
    )
  in
  let closingopt =
    match cycleopt with
    | None -> None

    | Some(PathLineTo(())) -> Some(GraphicData.LineTo(()))

    | Some(PathCubicBezierTo(astpt1, astpt2, ())) ->
        let pt1 = interpret_point env astpt1 in
        let pt2 = interpret_point env astpt2 in
          Some(GraphicData.CubicBezierTo(pt1, pt2, ()))
  in
    (pathelemlst, closingopt)


and interpret_input_horz_content env (ihlst : input_horz_element list) =
  ihlst |> List.map (function
    | InputHorzText(s) ->
        ImInputHorzText(s)

    | InputHorzEmbedded(astcmd, astarglst) ->
        ImInputHorzEmbedded(astcmd, astarglst)

    | InputHorzEmbeddedMath(astmath) ->
        ImInputHorzEmbeddedMath(astmath)

    | InputHorzContent(ast) ->
        let value = interpret env ast in
        begin
          match value with
          | InputHorzWithEnvironment(imihlst, envsub) ->
              ImInputHorzContent(imihlst, envsub)

          | _ -> report_bug_reduction "interpret_input_horz_content" ast value
        end
  )

and interpret_input_vert_content env (ivlst : input_vert_element list) =
  ivlst |> List.map (function
    | InputVertEmbedded(astcmd, astarglst) ->
        ImInputVertEmbedded(astcmd, astarglst)

    | InputVertContent(ast) ->
        let value = interpret env ast in
        begin
          match value with
          | InputVertWithEnvironment(imivlst, envsub) ->
              ImInputVertContent(imivlst, envsub)

          | _ -> report_bug_reduction "interpret_input_vert_content" ast value
        end
  )


and interpret env ast =
  match ast with

(* ---- basic value ---- *)

  | Value(v) -> v

  | FinishHeaderFile -> EvaluatedEnvironment(env)

  | FinishStruct -> EvaluatedEnvironment(env)

  | InputHorz(ihlst) ->
      let imihlst = interpret_input_horz_content env ihlst in
        InputHorzWithEnvironment(imihlst, env)
          (* -- lazy evaluation; evaluates embedded variables only -- *)

  | InputVert(ivlst) ->
      let imivlst = interpret_input_vert_content env ivlst in
        InputVertWithEnvironment(imivlst, env)
          (* -- lazy evaluation; evaluates embedded variables only -- *)

  | LengthDescription(flt, unitnm) ->
      let len =
        match unitnm with  (* temporary; ad-hoc handling of unit names *)
        | "pt"   -> Length.of_pdf_point flt
        | "cm"   -> Length.of_centimeter flt
        | "mm"   -> Length.of_millimeter flt
        | "inch" -> Length.of_inch flt
        | _      -> report_bug_ast "LengthDescription; unknown unit name" ast
      in
        LengthConstant(len)

  | Concat(ast1, ast2) ->
      let value1 = interpret env ast1 in
      let value2 = interpret env ast2 in
        begin
          match (value1, value2) with
          | (StringEmpty, _)                         -> value2
          | (_, StringEmpty)                         -> value1
          | (StringConstant(s1), StringConstant(s2)) -> StringConstant(s1 ^ s2)
          | _                                        -> report_bug_reduction "Concat" ast1 value1
        end

(* ---- values for backend ---- *)

  | PrimitiveSetMathVariantToChar(asts, astmccls, astmathcls, aststr, astctx) ->
      let s = interpret_string env asts in
      let mccls = interpret_math_char_class env astmccls in
      let is_big = false in
      let mathcls = interpret_math_class env astmathcls in
      let uchlst = interpret_uchar_list env aststr in
      let (ctx, v) = interpret_context env astctx in
      let mvvalue = (mathcls, HorzBox.MathVariantToChar(is_big, uchlst)) in
      let mcclsmap = ctx.HorzBox.math_variant_char_map in
        Context(HorzBox.({ ctx with math_variant_char_map = mcclsmap |> MathVariantCharMap.add (s, mccls) mvvalue }), v)

  | PrimitiveSetMathCommand(astcmd, astctx) ->
      let valuecmd = interpret env astcmd in
      let (ctx, _) = interpret_context env astctx in
        Context(ctx, valuecmd)

  | BackendMathVariantCharDirect(astmathcls, astrcd) ->   (* TEMPORARY; should extend more *)
      let mathcls = interpret_math_class env astmathcls in
      let is_big = false in  (* temporary *)
      let valuercd = interpret env astrcd in
      let mvsty = get_math_variant_style valuercd in
        MathValue(HorzBox.([MathPure(MathVariantCharDirect(mathcls, is_big, mvsty))]))

  | BackendMathConcat(astm1, astm2) ->
      let mlst1 = interpret_math env astm1 in
      let mlst2 = interpret_math env astm2 in
        MathValue(List.append mlst1 mlst2)

  | BackendMathList(astmlst) ->
      let mlstlst = List.map (interpret_math env) astmlst in  (* slightly doubtful in terms of evaluation strategy *)
        MathValue(List.concat mlstlst)

  | BackendMathGroup(astmathcls1, astmathcls2, astm) ->
      let mathcls1 = interpret_math_class env astmathcls1 in
      let mathcls2 = interpret_math_class env astmathcls2 in
      let mlst = interpret_math env astm in
        MathValue([MathGroup(mathcls1, mathcls2, mlst)])

  | BackendMathSuperscript(astm1, astm2) ->
      let mlst1 = interpret_math env astm1 in
      let mlst2 = interpret_math env astm2 in
        MathValue([MathSuperscript(mlst1, mlst2)])

  | BackendMathSubscript(astm1, astm2) ->
      let mlst1 = interpret_math env astm1 in
      let mlst2 = interpret_math env astm2 in
        MathValue([MathSubscript(mlst1, mlst2)])

  | BackendMathFraction(astm1, astm2) ->
      let mlst1 = interpret_math env astm1 in
      let mlst2 = interpret_math env astm2 in
        MathValue([MathFraction(mlst1, mlst2)])

  | BackendMathRadical(astm1, astm2) ->
      let mlst1opt = interpret_option interpret env get_math astm1 in
      let mlst2 = interpret_math env astm2 in
      let radical = Primitives.default_radical in  (* temporary; should be variable *)
      begin
        match mlst1opt with
        | None        -> MathValue([MathRadical(radical, mlst2)])
        | Some(mlst1) -> MathValue([MathRadicalWithDegree(mlst1, mlst2)])
      end

  | BackendMathParen(astparenL, astparenR, astm1) ->
      let reducef = reduce_beta_list in
      let mlst1 = interpret_math env astm1 in
      let valueparenL = interpret env astparenL in
      let valueparenR = interpret env astparenR in
      let parenL = make_paren reducef valueparenL in
      let parenR = make_paren reducef valueparenR in
        MathValue([MathParen(parenL, parenR, mlst1)])

  | BackendMathUpperLimit(astm1, astm2) ->
      let mlst1 = interpret_math env astm1 in
      let mlst2 = interpret_math env astm2 in
        MathValue([MathUpperLimit(mlst1, mlst2)])

  | BackendMathLowerLimit(astm1, astm2) ->
      let mlst1 = interpret_math env astm1 in
      let mlst2 = interpret_math env astm2 in
        MathValue([MathLowerLimit(mlst1, mlst2)])

  | BackendMathChar(astmathcls, aststr) ->
      let mathcls = interpret_math_class env astmathcls in
      let s = interpret_string env aststr in
      let uchlst = (InternalText.to_uchar_list (InternalText.of_utf8 s)) in
      let mlst = [HorzBox.(MathPure(MathElement(mathcls, MathChar(false, uchlst))))] in
        MathValue(mlst)

  | BackendMathBigChar(astmathcls, aststr) ->
      let mathcls = interpret_math_class env astmathcls in
      let s = interpret_string env aststr in
      let uchlst = (InternalText.to_uchar_list (InternalText.of_utf8 s)) in
      let mlst = [HorzBox.(MathPure(MathElement(mathcls, MathChar(true, uchlst))))] in
        MathValue(mlst)

  | BackendMathCharWithKern(astmathcls, aststr, astkernfL, astkernfR) ->
      let reducef = reduce_beta_list in
      let mathcls = interpret_math_class env astmathcls in
      let s = interpret_string env aststr in
      let valuekernfL = interpret env astkernfL in
      let valuekernfR = interpret env astkernfR in
      let uchlst = (InternalText.to_uchar_list (InternalText.of_utf8 s)) in
      let kernfL = make_math_char_kern_func reducef valuekernfL in
      let kernfR = make_math_char_kern_func reducef valuekernfR in
      let mlst = [HorzBox.(MathPure(MathElement(mathcls, MathCharWithKern(false, uchlst, kernfL, kernfR))))] in
        MathValue(mlst)

  | BackendMathBigCharWithKern(astmathcls, aststr, astkernfL, astkernfR) ->
      let reducef = reduce_beta_list in
      let mathcls = interpret_math_class env astmathcls in
      let s = interpret_string env aststr in
      let valuekernfL = interpret env astkernfL in
      let valuekernfR = interpret env astkernfR in
      let uchlst = (InternalText.to_uchar_list (InternalText.of_utf8 s)) in
      let kernfL = make_math_char_kern_func reducef valuekernfL in
      let kernfR = make_math_char_kern_func reducef valuekernfR in
      let mlst = [HorzBox.(MathPure(MathElement(mathcls, MathCharWithKern(true, uchlst, kernfL, kernfR))))] in
        MathValue(mlst)

  | BackendMathText(astmathcls, astf) ->
      let reducef = reduce_beta_list in
      let mathcls = interpret_math_class env astmathcls in
      let valuef = interpret env astf in
      let hblstf ictx =
(*
          Format.printf "Evaluator> BackendMathText\n";
          Format.printf "%a\n" pp_syntactic_value valuef;
*)
        let valueh = reducef valuef [Context(ictx)] in
          get_horz valueh
      in
        MathValue(HorzBox.([MathPure(MathElement(mathcls, MathEmbeddedText(hblstf)))]))

  | BackendMathColor(astcolor, astm) ->
      let color = interpret_color env astcolor in
      let mlst = interpret_math env astm in
        MathValue(HorzBox.([MathChangeContext(MathChangeColor(color), mlst)]))

  | BackendMathCharClass(astmccls, astm) ->
      let mccls = interpret_math_char_class env astmccls in
      let mlst = interpret_math env astm in
        MathValue(HorzBox.([MathChangeContext(MathChangeMathCharClass(mccls), mlst)]))

  | BackendEmbeddedMath(astctx, astm) ->
      let ictx = interpret_context env astctx in
      let mlst = interpret_math env astm in
      let mathctx = MathContext.make ictx in
      let hblst = Math.main mathctx mlst in
        Horz(hblst)

  | BackendTabular(asttabular, astrulesf) ->
      let get_row : syntactic_value -> HorzBox.cell list = get_list get_cell in
      let tabular : HorzBox.row list = interpret_list interpret env get_row asttabular in
      let (imtabular, widlst, lenlst, wid, hgt, dpt) = Tabular.main tabular in
      let valuerulesf = interpret env astrulesf in
      let rulesf xs ys =
        let valueret =
          reduce_beta_list valuerulesf [make_length_list xs; make_length_list ys]
        in
        graphics_of_list valueret
      in
        Horz(HorzBox.([HorzPure(PHGFixedTabular(wid, hgt, dpt, imtabular, widlst, lenlst, rulesf))]))

  | BackendRegisterPdfImage(aststr, astpageno) ->
      let srcpath = interpret_string env aststr in
      let pageno = interpret_int env astpageno in
      let imgkey = ImageInfo.add_pdf srcpath pageno in
        ImageKey(imgkey)

  | BackendRegisterOtherImage(aststr) ->
      let srcpath = interpret_string env aststr in
      let imgkey = ImageInfo.add_image srcpath in
        ImageKey(imgkey)

  | BackendUseImageByWidth(astimg, astwid) ->
      let valueimg = interpret env astimg in
      let wid = interpret_length env astwid in
      begin
        match valueimg with
        | ImageKey(imgkey) ->
            let hgt = ImageInfo.get_height_from_width imgkey wid in
              Horz(HorzBox.([HorzPure(PHGFixedImage(wid, hgt, imgkey))]))

        | _ -> report_bug_reduction "BackendUseImage" astimg valueimg
      end

  | BackendHookPageBreak(asthook) ->
      let reducef = reduce_beta_list in
      let valuehook = interpret env asthook in
      let hookf = make_hook reducef valuehook in
        Horz(HorzBox.([HorzPure(PHGHookPageBreak(hookf))]))

  | Path(astpt0, pathcomplst, cycleopt) ->
      let pt0 = interpret_point env astpt0 in
      let (pathelemlst, closingopt) = interpret_path env pathcomplst cycleopt in
        PathValue([GraphicData.GeneralPath(pt0, pathelemlst, closingopt)])

  | PathUnite(astpath1, astpath2) ->
      let pathlst1 = interpret_path_value env astpath1 in
      let pathlst2 = interpret_path_value env astpath2 in
        PathValue(List.append pathlst1 pathlst2)

  | PrePathBeginning(astpt0) ->
      let pt0 = interpret_point env astpt0 in
        PrePathValue(PrePath.start pt0)

  | PrePathLineTo(astpt1, astprepath) ->
      let pt1 = interpret_point env astpt1 in
      let prepath = interpret_prepath env astprepath in
        PrePathValue(prepath |> PrePath.line_to pt1)

  | PrePathCubicBezierTo(astptS, astptT, astpt1, astprepath) ->
      let ptS = interpret_point env astptS in
      let ptT = interpret_point env astptT in
      let pt1 = interpret_point env astpt1 in
      let prepath = interpret_prepath env astprepath in
        PrePathValue(prepath |> PrePath.bezier_to ptS ptT pt1)

  | PrePathTerminate(astprepath) ->
      let prepath = interpret_prepath env astprepath in
        PathValue([prepath |> PrePath.terminate])

  | PrePathCloseWithLine(astprepath) ->
      let prepath = interpret_prepath env astprepath in
        PathValue([prepath |> PrePath.close_with_line])

  | PrePathCloseWithCubicBezier(astptS, astptT, astprepath) ->
      let ptS = interpret_point env astptS in
      let ptT = interpret_point env astptT in
      let prepath = interpret_prepath env astprepath in
        PathValue([prepath |> PrePath.close_with_bezier ptS ptT])

  | HorzConcat(ast1, ast2) ->
      let hblst1 = interpret_horz env ast1 in
      let hblst2 = interpret_horz env ast2 in
        Horz(List.append hblst1 hblst2)

  | VertConcat(ast1, ast2) ->
      let vblst1 = interpret_vert env ast1 in
      let vblst2 = interpret_vert env ast2 in
        Vert(List.append vblst1 vblst2)

  | LambdaVert(evid, astdef) -> LambdaVertWithEnvironment(evid, astdef, env)

  | LambdaHorz(evid, astdef) -> LambdaHorzWithEnvironment(evid, astdef, env)

  | HorzLex(astctx, ast1) ->
      let valuectx = interpret env astctx in
      let value1 = interpret env ast1 in
      begin
        match value1 with
        | InputHorzWithEnvironment(imihlst, envi) -> interpret_intermediate_input_horz envi valuectx imihlst
        | _                                       -> report_bug_reduction "HorzLex" ast1 value1
      end

  | VertLex(astctx, ast1) ->
      let valuectx = interpret env astctx in
      let value1 = interpret env ast1 in
      begin
        match value1 with
        | InputVertWithEnvironment(imivlst, envi) -> interpret_intermediate_input_vert envi valuectx imivlst
        | _                                       -> report_bug_reduction "VertLex" ast1 value1
      end

  | BackendFont(astabbrev, astszrat, astrsrat) ->
      let abbrev = interpret_string env astabbrev in
      let size_ratio = interpret_float env astszrat in
      let rising_ratio = interpret_float env astrsrat in
        make_font_value (abbrev, size_ratio, rising_ratio)

  | BackendLineBreaking(astb1, astb2, astctx, asthorz) ->
      let is_breakable_top = interpret_bool env astb1 in
      let is_breakable_bottom = interpret_bool env astb2 in
      let (ctx, _) = interpret_context env astctx in
      let hblst = interpret_horz env asthorz in
      let imvblst = HorzBox.(LineBreak.main is_breakable_top is_breakable_bottom ctx.paragraph_top ctx.paragraph_bottom ctx hblst) in
        Vert(imvblst)

  | BackendPageBreaking(astpagesize, astpagecontf, astpagepartsf, astvert) ->
      let reducef = reduce_beta_list in
      let pagesize = interpret_page_size env astpagesize in
      let valuepagecontf = interpret env astpagecontf in
      let pagecontf = make_page_content_scheme_func reducef valuepagecontf in
      let valuepagepartsf = interpret env astpagepartsf in
      let pagepartsf = make_page_parts_scheme_func reducef valuepagepartsf in
      let vblst = interpret_vert env astvert in
        DocumentValue(pagesize, pagecontf, pagepartsf, vblst)

  | BackendVertFrame(astctx, astpads, astdecoset, astk) ->
      let reducef = reduce_beta_list in
      let (ctx, valuecmd) = interpret_context env astctx in
      let valuek = interpret env astk in
      let pads = interpret_paddings env astpads in
      let (valuedecoS, valuedecoH, valuedecoM, valuedecoT) = interpret_decoset env astdecoset in
      let valuectxsub =
        Context(HorzBox.({ ctx with paragraph_width = HorzBox.(ctx.paragraph_width -% pads.paddingL -% pads.paddingR) }), valuecmd)
      in
      let vblst =
        let valuev = reducef valuek [valuectxsub] in
          get_vert valuev
      in
        Vert(HorzBox.([
          VertTopMargin(true, ctx.paragraph_top);
          VertFrame(pads,
                      make_frame_deco reducef valuedecoS,
                      make_frame_deco reducef valuedecoH,
                      make_frame_deco reducef valuedecoM,
                      make_frame_deco reducef valuedecoT,
                      ctx.paragraph_width, vblst);
          VertBottomMargin(true, ctx.paragraph_bottom);
        ]))

  | BackendEmbeddedVertTop(astctx, astlen, astk) ->
      let reducef = reduce_beta_list in
      let (ctx, valuecmd) = interpret_context env astctx in
      let wid = interpret_length env astlen in
      let valuek = interpret env astk in
      let valuectxsub =
        Context(HorzBox.({ ctx with paragraph_width = wid; }), valuecmd)
      in
      let vblst =
        let valuev = reducef valuek [valuectxsub] in
          get_vert valuev
      in
      let imvblst = PageBreak.solidify vblst in
      let (hgt, dpt) = adjust_to_first_line imvblst in
(*
      let () = PrintForDebug.embvertE (Format.sprintf "EmbeddedVert: height = %f, depth = %f" (Length.to_pdf_point hgt) (Length.to_pdf_point dpt)) in  (* for debug *)
*)
        Horz(HorzBox.([HorzPure(PHGEmbeddedVert(wid, hgt, dpt, imvblst))]))

  | BackendVertSkip(astlen) ->
      let len = interpret_length env astlen in
        Vert(HorzBox.([VertFixedBreakable(len)]))

  | BackendEmbeddedVertBottom(astctx, astlen, astk) ->
      let reducef = reduce_beta_list in
      let (ctx, valuecmd) = interpret_context env astctx in
      let wid = interpret_length env astlen in
      let valuek = interpret env astk in
      let valuectxsub =
        Context(HorzBox.({ ctx with paragraph_width = wid; }), valuecmd)
      in
      let vblst =
        let valuev = reducef valuek [valuectxsub] in
          get_vert valuev
      in
      let imvblst = PageBreak.solidify vblst in
      let (hgt, dpt) = adjust_to_last_line imvblst in
(*
      let () = PrintForDebug.embvertE (Format.sprintf "EmbeddedVert: height = %f, depth = %f" (Length.to_pdf_point hgt) (Length.to_pdf_point dpt)) in  (* for debug *)
*)
        Horz(HorzBox.([HorzPure(PHGEmbeddedVert(wid, hgt, dpt, imvblst))]))

  | BackendLineStackTop(astlst) ->
      let hblstlst = interpret_list interpret env get_horz astlst in
      let (wid, vblst) = make_line_stack hblstlst in
      let imvblst = PageBreak.solidify vblst in
      let (hgt, dpt) = adjust_to_first_line imvblst in
        Horz(HorzBox.([HorzPure(PHGEmbeddedVert(wid, hgt, dpt, imvblst))]))

  | BackendLineStackBottom(astlst) ->
      let hblstlst = interpret_list interpret env get_horz astlst in
      let (wid, vblst) = make_line_stack hblstlst in
      let imvblst = PageBreak.solidify vblst in
      let (hgt, dpt) = adjust_to_last_line imvblst in
        Horz(HorzBox.([HorzPure(PHGEmbeddedVert(wid, hgt, dpt, imvblst))]))

  | PrimitiveGetInitialContext(astwid, astcmd) ->
      let txtwid = interpret_length env astwid in
      let valuecmd = interpret env astcmd in
        Context(Primitives.get_initial_context txtwid, valuecmd)

  | PrimitiveSetSpaceRatio(astratio, astctx) ->
      let ratio = interpret_float env astratio in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with space_natural = ratio; }), valuecmd)

  | PrimitiveSetParagraphMargin(asttop, astbottom, astctx) ->
      let lentop = interpret_length env asttop in
      let lenbottom = interpret_length env astbottom in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with
          paragraph_top    = lentop;
          paragraph_bottom = lenbottom;
        }), valuecmd)

  | PrimitiveSetFontSize(astsize, astctx) ->
      let size = interpret_length env astsize in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with font_size = size; }), valuecmd)

  | PrimitiveGetFontSize(astctx) ->
      let (ctx, _) = interpret_context env astctx in
        LengthConstant(ctx.HorzBox.font_size)

  | PrimitiveSetFont(astscript, astfont, astctx) ->
      let script = interpret_script env astscript in
      let font_info = interpret_font env astfont in
      let (ctx, valuecmd) = interpret_context env astctx in
      let font_scheme_new = HorzBox.(ctx.font_scheme |> CharBasis.ScriptSchemeMap.add script font_info) in
        Context(HorzBox.({ ctx with font_scheme = font_scheme_new; }), valuecmd)

  | PrimitiveGetFont(astscript, astctx) ->
      let script = interpret_script env astscript in
      let (ctx, _) = interpret_context env astctx in
      let fontwr = HorzBox.get_font_with_ratio ctx script in
        make_font_value fontwr

  | PrimitiveSetMathFont(aststr, astctx) ->
      let mfabbrev = interpret_string env aststr in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with math_font = mfabbrev; }), valuecmd)

  | PrimitiveSetDominantWideScript(astscript, astctx) ->
      let script = interpret_script env astscript in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with dominant_wide_script = script; }), valuecmd)

  | PrimitiveGetDominantWideScript(astctx) ->
      let (ctx, _) = interpret_context env astctx in
        make_script_value ctx.HorzBox.dominant_wide_script

  | PrimitiveSetDominantNarrowScript(astscript, astctx) ->
      let script = interpret_script env astscript in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with dominant_narrow_script = script; }), valuecmd)

  | PrimitiveGetDominantNarrowScript(astctx) ->
      let (ctx, _) = interpret_context env astctx in
        make_script_value ctx.HorzBox.dominant_narrow_script

  | PrimitiveSetLangSys(astscript, astlangsys, astctx) ->
      let script = interpret_script env astscript in
      let langsys = interpret_language_system env astlangsys in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with langsys_scheme = ctx.langsys_scheme |> CharBasis.ScriptSchemeMap.add script langsys}), valuecmd)

  | PrimitiveGetLangSys(astscript, astctx) ->
      let script = interpret_script env astscript in
      let (ctx, _) = interpret_context env astctx in
      let langsys = HorzBox.get_language_system ctx script in
        make_language_system_value langsys

  | PrimitiveSetTextColor(astcolor, astctx) ->
      let color = interpret_color env astcolor in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with text_color = color; }), valuecmd)

  | PrimitiveGetTextColor(astctx) ->
      let (ctx, _) = interpret_context env astctx in
      let color = ctx.HorzBox.text_color in
        make_color_value color

  | PrimitiveSetLeading(astlen, astctx) ->
      let len = interpret_length env astlen in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with leading = len; }), valuecmd)

  | PrimitiveGetTextWidth(astctx) ->
      let (ctx, _) = interpret_context env astctx in
        LengthConstant(ctx.HorzBox.paragraph_width)

  | PrimitiveSetManualRising(astrising, astctx) ->
      let rising = interpret_length env astrising in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with manual_rising = rising; }), valuecmd)

  | PrimitiveSetHyphenPenalty(astpnlty, astctx) ->
      let pnlty = interpret_int env astpnlty in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with hyphen_badness = pnlty; }), valuecmd)

  | PrimitiveEmbed(aststr) ->
      let str = interpret_string env aststr in
        InputHorzWithEnvironment([ImInputHorzText(str)], env)

  | PrimitiveGetAxisHeight(astctx) ->
      let (ctx, _) = interpret_context env astctx in
      let fontsize = ctx.HorzBox.font_size in
      let mfabbrev = ctx.HorzBox.math_font in
      let hgt = FontInfo.get_axis_height mfabbrev fontsize in
        LengthConstant(hgt)

  | PrimitiveSetEveryWordBreak(asth1, asth2, astctx) ->
      let hblst1 = interpret_horz env asth1 in
      let hblst2 = interpret_horz env asth2 in
      let (ctx, valuecmd) = interpret_context env astctx in
        Context(HorzBox.({ ctx with
          before_word_break = hblst1;
          after_word_break = hblst2;
        }), valuecmd)

  | BackendFixedEmpty(astwid) ->
      let wid = interpret_length env astwid in
        Horz([HorzBox.HorzPure(HorzBox.PHSFixedEmpty(wid))])

  | BackendOuterEmpty(astnat, astshrink, aststretch) ->
      let widnat = interpret_length env astnat in
      let widshrink = interpret_length env astshrink in
      let widstretch = interpret_length env aststretch in
        Horz([HorzBox.HorzPure(HorzBox.PHSOuterEmpty(widnat, widshrink, widstretch))])

  | BackendOuterFrame(astpads, astdeco, asth) ->
      let reducef = reduce_beta_list in
      let pads = interpret_paddings env astpads in
      let hblst = interpret_horz env asth in
      let valuedeco = interpret env astdeco in
        Horz([HorzBox.HorzPure(HorzBox.PHGOuterFrame(
          pads,
          make_frame_deco reducef valuedeco,
          hblst))])

  | BackendInnerFrame(astpads, astdeco, asth) ->
      let reducef = reduce_beta_list in
      let pads = interpret_paddings env astpads in
      let hblst = interpret_horz env asth in
      let valuedeco = interpret env astdeco in
        Horz([HorzBox.HorzPure(HorzBox.PHGInnerFrame(
          pads,
          make_frame_deco reducef valuedeco,
          hblst))])

  | BackendFixedFrame(astwid, astpads, astdeco, asth) ->
      let reducef = reduce_beta_list in
      let wid = interpret_length env astwid in
      let pads = interpret_paddings env astpads in
      let hblst = interpret_horz env asth in
      let valuedeco = interpret env astdeco in
        Horz([HorzBox.HorzPure(HorzBox.PHGFixedFrame(
          pads, wid,
          make_frame_deco reducef valuedeco,
          hblst))])

  | BackendOuterFrameBreakable(astpads, astdecoset, asth) ->
      let reducef = reduce_beta_list in
      let pads = interpret_paddings env astpads in
      let hblst = interpret_horz env asth in
      let (valuedecoS, valuedecoH, valuedecoM, valuedecoT) = interpret_decoset env astdecoset in
        Horz([HorzBox.HorzFrameBreakable(
          pads, Length.zero, Length.zero,
          make_frame_deco reducef valuedecoS,
          make_frame_deco reducef valuedecoH,
          make_frame_deco reducef valuedecoM,
          make_frame_deco reducef valuedecoT,
          hblst
        )])

  | BackendInlineGraphics(astwid, asthgt, astdpt, astg) ->
      let reducef = reduce_beta_list in
      let wid = interpret_length env astwid in
      let hgt = interpret_length env asthgt in
      let dpt = interpret_length env astdpt in
      let valueg = interpret env astg in
      let graphics = make_inline_graphics reducef valueg in
        Horz(HorzBox.([HorzPure(PHGFixedGraphics(wid, hgt, Length.negate dpt, graphics))]))

  | BackendScriptGuard(astscript, asth) ->
      let script = interpret_script env astscript in
      let hblst = interpret_horz env asth in
        Horz(HorzBox.([HorzScriptGuard(script, hblst)]))

  | BackendDiscretionary(astpb, asth0, asth1, asth2) ->
      let pb = interpret_int env astpb in
      let hblst0 = interpret_horz env asth0 in
      let hblst1 = interpret_horz env asth1 in
      let hblst2 = interpret_horz env asth2 in
        Horz(HorzBox.([HorzDiscretionary(pb, hblst0, hblst1, hblst2)]))

  | BackendRegisterCrossReference(astk, astv) ->
      let k = interpret_string env astk in
      let v = interpret_string env astv in
      begin
        CrossRef.register k v;
        UnitConstant
      end

  | BackendProbeCrossReference(astk) ->
      let k = interpret_string env astk in
      begin
        match CrossRef.probe k with
        | None    -> Constructor("None", UnitConstant)
        | Some(v) -> Constructor("Some", StringConstant(v))
      end

  | BackendGetCrossReference(astk) ->
      let k = interpret_string env astk in
      begin
        match CrossRef.get k with
        | None    -> Constructor("None", UnitConstant)
        | Some(v) -> Constructor("Some", StringConstant(v))
      end

  | PrimitiveGetNaturalWidth(asthorz) ->
      let hblst = interpret_horz env asthorz in
      let (wid, _, _) = LineBreak.get_natural_metrics hblst in
        LengthConstant(wid)

  | PrimitiveGetNaturalLength(astvert) ->
      let vblst = interpret_vert env astvert in
      let imvblst = PageBreak.solidify vblst in
      let (hgt, dpt) = adjust_to_first_line imvblst in
        LengthConstant(hgt +% (Length.negate dpt))

  | PrimitiveDisplayMessage(aststr) ->
      let str = interpret_string env aststr in
        print_endline str;
        UnitConstant

  | PrimitiveTupleCons(asthd, asttl) ->
      let valuehd = interpret env asthd in
      let valuetl = interpret env asttl in
        TupleCons(valuehd, valuetl)

  | PrimitiveListCons(asthd, asttl) ->
      let valuehd = interpret env asthd in
      let valuetl = interpret env asttl in
        ListCons(valuehd, valuetl)

(* -- fundamentals -- *)

  | ContentOf(rng, evid) ->
(*
      let () = PrintForDebug.evalE ("ContentOf(" ^ (EvalVarID.show_direct evid) ^ ")") in  (* for debug *)
*)
      begin
        match find_in_environment env evid with
        | Some(rfvalue) ->
          let value = !rfvalue in
(*
          let () = PrintForDebug.evalE ("  -> " ^ (show_syntactic_value value)) in  (* for debug *)
*)
(*
          Format.printf "Evaluator> ContentOf: %s ---> %s\n" (EvalVarID.show_direct evid) (show_syntactic_value value);
*)
            value

        | None ->
            report_bug_ast ("ContentOf: variable '" ^ (EvalVarID.show_direct evid) ^ "' (at " ^ (Range.to_string rng) ^ ") not found") ast
      end

  | LetRecIn(recbinds, ast2) ->
      let envnew = add_letrec_bindings_to_environment env recbinds in
        interpret envnew ast2

  | LetNonRecIn(pat, ast1, ast2) ->
      let value1 = interpret env ast1 in
        select_pattern (Range.dummy "LetNonRecIn") env value1 [PatternBranch(pat, ast2)]

  | Function(patbrs) ->
      FuncWithEnvironment(patbrs, env)

  | Apply(ast1, ast2) ->
(*
      let () = PrintForDebug.evalE ("Apply(" ^ (show_abstract_tree ast1) ^ ", " ^ (show_abstract_tree ast2) ^ ")") in  (* for debug *)
*)
      let value1 = interpret env ast1 in
      begin
        match value1 with
        | FuncWithEnvironment(patbrs, env1) ->
            let value2 = interpret env ast2 in
              select_pattern (Range.dummy "Apply") env1 value2 patbrs

        | PrimitiveWithEnvironment(patbrs, env1, _, _) ->
            let value2 = interpret env ast2 in
                          select_pattern (Range.dummy "Apply") env1 value2 patbrs

        | _ -> report_bug_reduction "Apply: not a function" ast1 value1
      end

  | IfThenElse(astb, ast1, ast2) ->
      let b = interpret_bool env astb in
        if b then interpret env ast1 else interpret env ast2

(* ---- record ---- *)

  | Record(asc) ->
      RecordValue(Assoc.map_value (interpret env) asc)

  | AccessField(ast1, fldnm) ->
      let value1 = interpret env ast1 in
      begin
        match value1 with
        | RecordValue(asc1) ->
            begin
              match Assoc.find_opt asc1 fldnm with
              | None    -> report_bug_reduction ("AccessField: field '" ^ fldnm ^ "' not found") ast1 value1
              | Some(v) -> v
            end

        | _ -> report_bug_reduction "AccessField: not a Record" ast1 value1
      end

(* ---- imperatives ---- *)

  | LetMutableIn(evid, astini, astaft) ->
      let valueini = interpret env astini in
      let stid = register_location env valueini in
(*
      Format.printf "Evaluator> LetMutableIn; %s <- %s\n" (StoreID.show_direct stid) (show_syntactic_value valueini);  (* for debug *)
*)
      let envnew = add_to_environment env evid (ref (Location(stid))) in
        interpret envnew astaft

  | Sequential(ast1, ast2) ->
(*
      let () = PrintForDebug.evalE ("Sequential(" ^ (show_abstract_tree ast1) ^ ", " ^ (show_abstract_tree ast2) ^ ")") in  (* for debug *)
*)
      let value1 = interpret env ast1 in
(*
      let () = PrintForDebug.evalE ("value1 = " ^ (show_syntactic_value value1)) in  (* for debug *)
*)
      let value2 = interpret env ast2 in
(*
      let () = PrintForDebug.evalE ("value2 = " ^ (show_syntactic_value value2)) in  (* for debug *)
*)
        begin
          match value1 with
          | UnitConstant -> value2
          | _            -> report_bug_reduction "Sequential: first operand value is not a UnitConstant" ast1 value1
        end

  | Overwrite(evid, astnew) ->
      begin
        match find_in_environment env evid with
        | Some(rfvalue) ->
            let value = !rfvalue in
            begin
              match value with
              | Location(stid) ->
                  let valuenew = interpret env astnew in
(*
                  Format.printf "Evaluator> Overwrite; %s <- %s\n" (StoreID.show_direct stid) (show_syntactic_value valuenew);  (* for debug *)
*)
                    begin
                      update_location env stid valuenew;
                      UnitConstant
                    end
              | _ -> report_bug_value "Overwrite: value is not a Location" value
            end

        | None ->
            report_bug_ast ("Overwrite: mutable value '" ^ (EvalVarID.show_direct evid) ^ "' not found") ast
      end

  | WhileDo(astb, astc) ->
      if interpret_bool env astb then
        let _ = interpret env astc in interpret env (WhileDo(astb, astc))
      else
        UnitConstant

  | Dereference(astcont) ->
      let valuecont = interpret env astcont in
      begin
        match valuecont with
        | Location(stid) ->
            begin
              match find_location_value env stid with
              | Some(value) -> value
              | None        -> report_bug_reduction "Dereference; not found" astcont valuecont
            end

        | _ ->
            report_bug_reduction "Dereference" astcont valuecont
      end

(* ---- others ---- *)

  | PatternMatch(rng, astobj, patbrs) ->
      let valueobj = interpret env astobj in
        select_pattern rng env valueobj patbrs

  | NonValueConstructor(constrnm, astcont) ->
      let valuecont = interpret env astcont in
        Constructor(constrnm, valuecont)

  | Module(astmdl, astaft) ->
      let value = interpret env astmdl in
      begin
        match value with
        | EvaluatedEnvironment(envfinal) -> interpret envfinal astaft
        | _                              -> report_bug_reduction "Module" astmdl value
      end

(* -- primitive operation -- *)

  | PrimitiveSame(ast1, ast2) ->
      let str1 = interpret_string env ast1 in
      let str2 = interpret_string env ast2 in
        BooleanConstant(String.equal str1 str2)


  | PrimitiveStringSub(aststr, astpos, astwid) ->
      let str = interpret_string env aststr in
      let pos = interpret_int env astpos in
      let wid = interpret_int env astwid in
        let resstr =
          try String.sub str pos wid with
          | Invalid_argument(s) -> raise (EvalError("illegal index for 'string-sub'"))
        in
          StringConstant(resstr)

  | PrimitiveStringLength(aststr) ->
      let str = interpret_string env aststr in
        IntegerConstant(String.length str)

  | PrimitiveStringUnexplode(astil) ->
      let ilst = interpret_list interpret env get_int astil in
      let s =
        (List.map Uchar.of_int ilst) |> InternalText.of_uchar_list |> InternalText.to_utf8
      in
        StringConstant(s)

  | PrimitiveRegExpOfString(aststr) ->
      let str = interpret_string env aststr in
      let regexp =
        try Str.regexp str with
        | Failure(msg) -> raise (EvalError("regexp-of-string: " ^ msg))
      in
        RegExpConstant(regexp)

  | PrimitiveStringMatch(astpat, astr) ->
      let pat = interpret_regexp env astpat in
      let s   = interpret_string env astr in
      BooleanConstant(Str.string_match pat s 0)

  | PrimitiveSplitIntoLines(asts) ->
      let s = interpret_string env asts in
      let slst = String.split_on_char '\n' s in
      let pairlst = slst |> List.map chop_space_indent in
        pairlst |> make_list (fun (i, s) ->
          TupleCons(IntegerConstant(i), TupleCons(StringConstant(s), EndOfTuple)))

  | PrimitiveSplitOnRegExp(astre, aststr) ->
      let sep = interpret_regexp env astre in
      let str = interpret_string env aststr in
      let slst = Str.split sep str in
      let pairlst = slst |> List.map chop_space_indent in
        pairlst |> make_list (fun (i, s) ->
          TupleCons(IntegerConstant(i), TupleCons(StringConstant(s), EndOfTuple)))

  | PrimitiveArabic(astnum) ->
      let num = interpret_int env astnum in StringConstant(string_of_int num)

  | PrimitiveFloat(ast1) ->
      let ic1 = interpret_int env ast1 in FloatConstant(float_of_int ic1)

  | PrimitiveRound(ast1) ->
      let fc1 = interpret_float env ast1 in IntegerConstant(int_of_float fc1)

  | PrimitiveDrawText(astpt, asth) ->
      let pt = interpret_point env astpt in
      let hblst = interpret_horz env asth in
      let (imhblst, _, _) = LineBreak.natural hblst in
      let grelem = Graphics.make_text pt imhblst in
        GraphicsValue(grelem)

  | PrimitiveDrawStroke(astwid, astcolor, astpath) ->
      let wid = interpret_length env astwid in
      let color = interpret_color env astcolor in
      let pathlst = interpret_path_value env astpath in
      let grelem = Graphics.make_stroke wid color pathlst in
        GraphicsValue(grelem)

  | PrimitiveDrawFill(astcolor, astpath) ->
      let color = interpret_color env astcolor in
      let pathlst = interpret_path_value env astpath in
      let grelem = Graphics.make_fill color pathlst in
        GraphicsValue(grelem)

  | PrimitiveDrawDashedStroke(astwid, astdash, astcolor, astpath) ->
      let wid = interpret_length env astwid in
      let (len1, len2, len3) =
        astdash |> interpret_tuple3 env get_length
      in
      let color = interpret_color env astcolor in
      let pathlst = interpret_path_value env astpath in
      let grelem = Graphics.make_dashed_stroke wid (len1, len2, len3) color pathlst in
        GraphicsValue(grelem)

  | Times(astl, astr) ->
      let numl = interpret_int env astl in
      let numr = interpret_int env astr in
        IntegerConstant(numl * numr)

  | Divides(astl, astr) ->
      let numl = interpret_int env astl in
      let numr = interpret_int env astr in
        begin
          try IntegerConstant(numl / numr) with
          | Division_by_zero -> raise (EvalError("division by zero"))
        end

  | Mod(astl, astr) ->
      let numl = interpret_int env astl in
      let numr = interpret_int env astr in
        begin
          try IntegerConstant(numl mod numr) with
          | Division_by_zero -> raise (EvalError("division by zero"))
        end

  | Plus(astl, astr) ->
      let numl = interpret_int env astl in
      let numr = interpret_int env astr in
        IntegerConstant(numl + numr)

  | Minus(astl, astr) ->
      let numl = interpret_int env astl in
      let numr = interpret_int env astr in
        IntegerConstant(numl - numr)

  | EqualTo(astl, astr) ->
      let numl = interpret_int env astl in
      let numr = interpret_int env astr in
        BooleanConstant(numl = numr)

  | GreaterThan(astl, astr) ->
      let numl = interpret_int env astl in
      let numr = interpret_int env astr in
        BooleanConstant(numl > numr)

  | LessThan(astl, astr) ->
      let numl = interpret_int env astl in
      let numr = interpret_int env astr in
        BooleanConstant(numl < numr)

  | LogicalAnd(astl, astr) ->
      let blnl = interpret_bool env astl in
      let blnr = interpret_bool env astr in
        BooleanConstant(blnl && blnr)

  | LogicalOr(astl, astr) ->
      let blnl = interpret_bool env astl in
      let blnr = interpret_bool env astr in
        BooleanConstant(blnl || blnr)

  | LogicalNot(astl) ->
      let blnl = interpret_bool env astl in
        BooleanConstant(not blnl)

  | FloatPlus(ast1, ast2) ->
      let flt1 = interpret_float env ast1 in
      let flt2 = interpret_float env ast2 in
        FloatConstant(flt1 +. flt2)

  | FloatMinus(ast1, ast2) ->
      let flt1 = interpret_float env ast1 in
      let flt2 = interpret_float env ast2 in
        FloatConstant(flt1 -. flt2)

  | FloatTimes(ast1, ast2) ->
      let flt1 = interpret_float env ast1 in
      let flt2 = interpret_float env ast2 in
        FloatConstant(flt1 *. flt2)

  | FloatDivides(ast1, ast2) ->
      let flt1 = interpret_float env ast1 in
      let flt2 = interpret_float env ast2 in
        FloatConstant(flt1 /. flt2)

  | FloatSine(ast1) ->
      let flt1 = interpret_float env ast1 in
        FloatConstant(sin flt1)

  | FloatArcSine(ast1) ->
      let flt1 = interpret_float env ast1 in
        FloatConstant(asin flt1)

  | FloatCosine(ast1) ->
      let flt1 = interpret_float env ast1 in
        FloatConstant(cos flt1)

  | FloatArcCosine(ast1) ->
      let flt1 = interpret_float env ast1 in
        FloatConstant(acos flt1)

  | FloatTangent(ast1) ->
      let flt1 = interpret_float env ast1 in
        FloatConstant(tan flt1)

  | FloatArcTangent(ast1) ->
      let flt1 = interpret_float env ast1 in
        FloatConstant(atan flt1)

  | FloatArcTangent2(ast1, ast2) ->
      let flt1 = interpret_float env ast1 in
      let flt2 = interpret_float env ast2 in
        FloatConstant(atan2 flt1 flt2)

  | LengthPlus(ast1, ast2) ->
      let len1 = interpret_length env ast1 in
      let len2 = interpret_length env ast2 in
        LengthConstant(HorzBox.(len1 +% len2))

  | LengthMinus(ast1, ast2) ->
      let len1 = interpret_length env ast1 in
      let len2 = interpret_length env ast2 in
        LengthConstant(HorzBox.(len1 -% len2))

  | LengthTimes(ast1, ast2) ->
      let len1 = interpret_length env ast1 in
      let flt2 = interpret_float env ast2 in
        LengthConstant(HorzBox.(len1 *% flt2))

  | LengthDivides(ast1, ast2) ->
      let len1 = interpret_length env ast1 in
      let len2 = interpret_length env ast2 in
        FloatConstant(HorzBox.(len1 /% len2))

  | LengthLessThan(ast1, ast2) ->
      let len1 = interpret_length env ast1 in
      let len2 = interpret_length env ast2 in
        BooleanConstant(HorzBox.(len1 <% len2))

  | LengthGreaterThan(ast1, ast2) ->
      let len1 = interpret_length env ast1 in
      let len2 = interpret_length env ast2 in
        BooleanConstant(HorzBox.(len2 <% len1))


and interpret_intermediate_input_vert env (valuectx : syntactic_value) (imivlst : intermediate_input_vert_element list) : syntactic_value =
  let rec interpret_commands env (imivlst : intermediate_input_vert_element list) =
    imivlst |> List.map (fun imiv ->
      match imiv with
      | ImInputVertEmbedded(astcmd, astarglst) ->
          let valuecmd = interpret env astcmd in
          begin
            match valuecmd with
            | LambdaVertWithEnvironment(evid, astdef, envf) ->
                let valuedef = reduce_beta envf evid valuectx astdef in
                let valuearglst =
                  astarglst |> List.fold_left (fun acc astarg ->
                    let valuearg = interpret env astarg in
                      Alist.extend acc valuearg
                  ) Alist.empty |> Alist.to_list
                    (* -- left-to-right evaluation -- *)
                in
                let valueret = reduce_beta_list valuedef valuearglst in
                  get_vert valueret

            | _ -> report_bug_reduction "interpret_intermediate_input_vert:1" astcmd valuecmd
          end

      | ImInputVertContent(imivlstsub, envsub) ->
          interpret_commands envsub imivlstsub

    ) |> List.concat
  in
  let imvblst = interpret_commands env imivlst in
    Vert(imvblst)


and interpret_intermediate_input_horz (env : environment) (valuectx : syntactic_value) (imihlst : intermediate_input_horz_element list) : syntactic_value =

  let (ctx, valuemcmd) = get_context valuectx in

  let rec normalize (imihlst : intermediate_input_horz_element list) =
    imihlst |> List.fold_left (fun acc imih ->
      match imih with
      | ImInputHorzEmbedded(astcmd, astarglst) ->
          let nmih = NomInputHorzEmbedded(astcmd, astarglst) in
            Alist.extend acc nmih

      | ImInputHorzText(s2) ->
          begin
            match Alist.chop_last acc with
            | Some(accrest, NomInputHorzText(s1)) -> (Alist.extend accrest (NomInputHorzText(s1 ^ s2)))
            | _                                   -> (Alist.extend acc (NomInputHorzText(s2)))
          end

      | ImInputHorzEmbeddedMath(astmath) ->
          let nmih = NomInputHorzEmbedded(Value(valuemcmd), [astmath]) in
            Alist.extend acc nmih

      | ImInputHorzContent(imihlstsub, envsub) ->
          let nmihlstsub = normalize imihlstsub in
          let nmih = NomInputHorzContent(nmihlstsub, envsub) in
            Alist.extend acc nmih

    ) Alist.empty |> Alist.to_list
  in

  let rec interpret_commands env (nmihlst : nom_input_horz_element list) : HorzBox.horz_box list =
    nmihlst |> List.map (fun nmih ->
      match nmih with
      | NomInputHorzEmbedded(astcmd, astarglst) ->
          let valuecmd = interpret env astcmd in
          begin
            match valuecmd with
            | LambdaHorzWithEnvironment(evid, astdef, envf) ->
                let valuedef = reduce_beta envf evid valuectx astdef in
                let valuearglst =
                  astarglst |> List.fold_left (fun acc astarg ->
                    let valuearg = interpret env astarg in
                      Alist.extend acc valuearg
                  ) Alist.empty |> Alist.to_list
                    (* -- left-to-right evaluation -- *)
                in
                let valueret = reduce_beta_list valuedef valuearglst in
                let hblst = get_horz valueret in
                  hblst

            | _ -> report_bug_reduction "interpret_input_horz" astcmd valuecmd
          end

      | NomInputHorzText(s) ->
          lex_horz_text ctx s

      | NomInputHorzContent(nmihlstsub, envsub) ->
          interpret_commands envsub nmihlstsub

    ) |> List.concat
  in

  let nmihlst = normalize imihlst in
  let hblst = interpret_commands env nmihlst in
    Horz(hblst)


and interpret_cell env ast : HorzBox.cell =
  let value = interpret env ast in
    get_cell value


and interpret_math_class env ast : HorzBox.math_kind =
  let value = interpret env ast in
    get_math_class value


and interpret_math env ast : math list =
  let value = interpret env ast in
    get_math value


and interpret_math_char_class env ast : HorzBox.math_char_class =
  let value = interpret env ast in
    get_math_char_class value


and interpret_script env ast : CharBasis.script =
  let value = interpret env ast in
    get_script value


and interpret_language_system env ast : CharBasis.language_system =
  let value = interpret env ast in
    get_language_system value


and interpret_string (env : environment) (ast : abstract_tree) : string =
  let value = interpret env ast in
    get_string value


and interpret_regexp (env : environment) (ast : abstract_tree) : Str.regexp =
  let value = interpret env ast in
    get_regexp value


and interpret_uchar_list (env : environment) (ast : abstract_tree) : Uchar.t list =
  let value = interpret env ast in
    get_uchar_list value


and interpret_path_value env ast : GraphicData.path list =
  let value = interpret env ast in
    get_path_value value


and interpret_context (env : environment) (ast : abstract_tree) : input_context =
  let value = interpret env ast in
    get_context value


and interpret_tuple3 env getf ast =
  let value = interpret env ast in
    get_tuple3 getf value


and interpret_color env ast : GraphicData.color =
  let value = interpret env ast in
    get_color value


and interpret_font (env : environment) (ast : abstract_tree) : HorzBox.font_with_ratio =
  let value = interpret env ast in
    get_font value


and interpret_bool (env : environment) (ast : abstract_tree) : bool =
  let value = interpret env ast in
    get_bool value


and interpret_int (env : environment) (ast : abstract_tree) : int =
  let value = interpret env ast in
    get_int value


and interpret_float (env : environment) (ast : abstract_tree) : float =
  let value = interpret env ast in
    get_float value


and interpret_length (env : environment) (ast : abstract_tree) : length =
  let value = interpret env ast in
    get_length value


and interpret_page_size env ast : HorzBox.page_size =
  let value = interpret env ast in
    get_page_size value


and select_pattern (rng : Range.t) (env : environment) (valueobj : syntactic_value) (patbrs : pattern_branch list) =
  let iter = select_pattern rng env valueobj in
  match patbrs with
  | [] ->
(*
      Format.printf "Evaluator> %a\n" pp_syntactic_value valueobj;
*)
      raise (EvalError("no matches (" ^ (Range.to_string rng) ^ ")"))

  | PatternBranch(pat, astto) :: tail ->
      let (b, envnew) = check_pattern_matching env pat valueobj in
        if b then
          interpret envnew astto
        else
          iter tail

  | PatternBranchWhen(pat, astcond, astto) :: tail ->
      let (b, envnew) = check_pattern_matching env pat valueobj in
      let cond = interpret_bool envnew astcond in
        if b && cond then
          interpret envnew astto
        else
          iter tail


and check_pattern_matching (env : environment) (pat : pattern_tree) (valueobj : syntactic_value) =
  let return b = (b, env) in
  match (pat, valueobj) with
  | (PIntegerConstant(pnc), IntegerConstant(nc)) -> return (pnc = nc)
  | (PBooleanConstant(pbc), BooleanConstant(bc)) -> return (pbc = bc)

  | (PStringConstant(ast1), value2) ->
      let str1 = interpret_string env ast1 in
      let str2 = get_string value2 in
        return (String.equal str1 str2)

  | (PUnitConstant, UnitConstant) -> return true
  | (PWildCard, _)                -> return true

  | (PVariable(evid), _) ->
      let envnew = add_to_environment env evid (ref valueobj) in
        (true, envnew)

  | (PAsVariable(evid, psub), sub) ->
      let envnew = add_to_environment env evid (ref sub) in
        check_pattern_matching envnew psub sub

  | (PEndOfList, EndOfList) -> return true

  | (PListCons(phd, ptl), ListCons(hd, tl)) ->
      let (bhd, envhd) = check_pattern_matching env phd hd in
      let (btl, envtl) = check_pattern_matching envhd ptl tl in
      if bhd && btl then
        (true, envtl)
      else
        return false

  | (PEndOfTuple, EndOfTuple) -> return true

  | (PTupleCons(phd, ptl), TupleCons(hd, tl)) ->
      let (bhd, envhd) = check_pattern_matching env phd hd in
      let (btl, envtl) = check_pattern_matching envhd ptl tl in
      if bhd && btl then
        (true, envtl)
      else
        return false

  | (PConstructor(cnm1, psub), Constructor(cnm2, sub))
      when cnm1 = cnm2 -> check_pattern_matching env psub sub

  | _ -> return false


and add_letrec_bindings_to_environment (env : environment) (recbinds : letrec_binding list) : environment =
  let trilst =
    recbinds |> List.map (function LetRecBinding(evid, patbrs) ->
      let loc = ref StringEmpty in
      (evid, loc, patbrs)
    )
  in
  let envnew =
    trilst @|> env @|> List.fold_left (fun envacc (evid, loc, _) ->
      add_to_environment envacc evid loc
    )
  in
  trilst |> List.iter (fun (evid, loc, patbrs) ->
(*
    Format.printf "Evaluator> letrec %s\n" (EvalVarID.show_direct evid);  (* for debug *)
*)
    loc := FuncWithEnvironment(patbrs, envnew)
  );

  (* begin: for debug *)
(*
  let () =
    let (valenv, _) = envnew in
    valenv |> EvalVarIDMap.iter (fun evid loc ->
      Format.printf "| %s =\n" (EvalVarID.show_direct evid);
    );
  in
*)
  (* end: for debug *)

  envnew
