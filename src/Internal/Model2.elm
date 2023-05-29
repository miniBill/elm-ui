module Internal.Model2 exposing (..)

import Animator
import Animator.Timeline
import Animator.Watcher
import Browser.Dom
import Html
import Html.Attributes as Attr
import Html.Events as Events
import Html.Keyed
import Html.Lazy
import Internal.BitEncodings as Bits
import Internal.BitField as BitField exposing (BitField)
import Internal.Bits.Analyze as AnalyzeBits
import Internal.Bits.Inheritance as Inheritance
import Internal.Flag as Flag exposing (Flag)
import Internal.Style.Generated as Generated
import Internal.Style2 as Style
import Internal.Teleport as Teleport
import Json.Decode as Json
import Json.Encode as Encode
import Set exposing (Set)
import Task
import Time
import VirtualDom


{-| -}
type Element msg
    = Element (Inheritance.Encoded -> Html.Html msg)


map : (a -> b) -> Element a -> Element b
map fn el =
    case el of
        Element elem ->
            Element
                (\s ->
                    Html.map fn (elem s)
                )


type Msg
    = Tick Time.Posix
    | Teleported Teleport.Trigger Teleport.Event



-- | BoxNew Id Box


type State
    = State
        { added : Set String
        , rules : List String
        , boxes : List ( Id, Box )
        }


type alias Box =
    { x : Float
    , y : Float
    , width : Float
    , height : Float
    }


{-| refreshed means this new box will completely replace an existing one.
-}
matchBox :
    Id
    -> List ( Id, Box )
    ->
        Maybe
            { box : Box
            , transition : Bool
            , others : List ( Id, Box )
            }
matchBox id boxes =
    matchBoxHelper id boxes []


matchBoxHelper ((Id identifier instance) as id) boxes passed =
    case boxes of
        [] ->
            Nothing

        ( (Id topIdentifier topInstance) as topId, topBox ) :: others ->
            if topIdentifier == identifier then
                Just
                    { box = topBox
                    , transition = instance /= topInstance
                    , others = passed ++ others
                    }

            else
                matchBoxHelper id others (( topId, topBox ) :: passed)


moveAnimationFixed className previous current =
    let
        from =
            bboxCss previous

        to =
            bboxCss current

        keyframes =
            "@keyframes " ++ className ++ " { from { " ++ from ++ " } to { " ++ to ++ "} }"

        classRule =
            "." ++ className ++ "{ position:fixed; animation: " ++ className ++ " 2000ms !important; animation-fill-mode: both !important; }"
    in
    keyframes ++ classRule


bboxCss box =
    "left:"
        ++ String.fromFloat box.x
        ++ "px; top: "
        ++ String.fromFloat box.y
        ++ "px; width:"
        ++ String.fromFloat box.width
        ++ "px; height:"
        ++ String.fromFloat box.height
        ++ "px;"


bboxTransform box =
    "transform:translate("
        ++ String.fromFloat box.x
        ++ "px, "
        ++ String.fromFloat box.y
        ++ "px); width:"
        ++ String.fromFloat box.width
        ++ "px; height:"
        ++ String.fromFloat box.height
        ++ "px;"


moveAnimation className previous current =
    let
        from =
            bboxTransform
                { x = previous.x - current.x
                , y = previous.y - current.y
                , width = previous.width
                , height = previous.height
                }

        to =
            bboxTransform
                { x = 0
                , y = 0
                , width = current.width
                , height = current.height
                }

        keyframes =
            "@keyframes " ++ className ++ " { from { " ++ from ++ " } to { " ++ to ++ "} }"

        classRule =
            ".ui-movable."
                ++ className
                ++ "{ animation: "
                ++ className
                ++ " 2000ms !important; animation-fill-mode: both !important; }"
    in
    keyframes ++ classRule


type alias Animator msg model =
    { animator : Animator.Watcher.Watching model
    , onStateChange : model -> List ( Time.Posix, msg )
    }


updateWith :
    (Msg -> msg)
    -> Msg
    -> State
    ->
        { ui : State -> model
        , timelines : Animator msg model
        }
    -> ( model, Cmd msg )
updateWith toAppMsg msg state config =
    let
        ( newState, stateCmd ) =
            update toAppMsg msg state
    in
    ( case msg of
        Tick newTime ->
            config.ui newState
                |> Animator.Watcher.update newTime config.timelines.animator

        _ ->
            config.ui newState
    , Cmd.batch
        [ stateCmd
        ]
    )


subscription : (Msg -> msg) -> State -> Animator msg model -> model -> Sub msg
subscription toAppMsg state animator model =
    Animator.Watcher.toSubscription (toAppMsg << Tick) model animator.animator


update : (Msg -> msg) -> Msg -> State -> ( State, Cmd msg )
update toAppMsg msg ((State details) as unchanged) =
    case msg of
        Tick _ ->
            ( unchanged, Cmd.none )

        Teleported trigger teleported ->
            let
                ( updated, cmds ) =
                    List.foldl
                        (applyTeleported teleported)
                        ( unchanged, [] )
                        teleported.data
            in
            ( updated
            , Cmd.map toAppMsg (Cmd.batch cmds)
            )


applyTeleported : Teleport.Event -> Teleport.Data -> ( State, List (Cmd Msg) ) -> ( State, List (Cmd Msg) )
applyTeleported event data ( (State state) as untouched, cmds ) =
    case data of
        Teleport.Persistent group instance ->
            let
                id =
                    Id group instance
            in
            -- if this id matches an existing box in the cache
            -- it means this box was previously rendered at the position found
            case matchBox id state.boxes of
                Nothing ->
                    ( State { state | boxes = ( id, event.box ) :: state.boxes }, cmds )

                Just found ->
                    ( untouched, cmds )

        Teleport.Css css ->
            if Set.member css.hash state.added then
                ( untouched, cmds )

            else
                let
                    cssClass =
                        "." ++ css.hash ++ "{" ++ addStylesToString css.props "" ++ "}"
                in
                ( State
                    { state
                        | rules =
                            state.rules
                                |> addRule cssClass
                                |> addRule css.keyframes
                        , added = Set.insert css.hash state.added
                    }
                , cmds
                )


addRule : String -> List String -> List String
addRule rule existingRules =
    if rule == "" then
        existingRules

    else
        rule :: existingRules


requestBoundingBoxes boxes =
    Task.succeed []
        |> requestBoundingBoxesHelper boxes


requestBoundingBoxesHelper boxes task =
    case boxes of
        [] ->
            task

        ( topId, topBox ) :: remaining ->
            let
                newTask =
                    task
                        |> Task.andThen
                            (\list ->
                                Browser.Dom.getElement (toCssId topId)
                                    |> Task.map
                                        (\newBox ->
                                            ( topId, newBox.element ) :: list
                                        )
                                    |> Task.onError
                                        (\_ -> Task.succeed list)
                            )
            in
            requestBoundingBoxesHelper remaining newTask


type alias Transform =
    { scale : Float
    , x : Float
    , y : Float
    , rotation : Float
    }


emptyTransform : Transform
emptyTransform =
    { scale = 1
    , x = 0
    , y = 0
    , rotation = 0
    }


renderProps : List ( String, String ) -> String -> String
renderProps props str =
    case props of
        [] ->
            str

        ( name, val ) :: remain ->
            renderProps remain
                (str ++ name ++ ":" ++ val ++ ";")


phaseName : Trigger -> String
phaseName trigger =
    case trigger of
        OnFocused ->
            "-focus"

        OnHovered ->
            "-hover"

        OnPressed ->
            "-active"

        OnIf on ->
            ""


phasePseudoClass : Trigger -> String
phasePseudoClass trigger =
    case trigger of
        OnFocused ->
            ":focus"

        OnHovered ->
            ":hover"

        OnPressed ->
            ":active"

        OnIf on ->
            ""


transformToString : Transform -> String
transformToString trans =
    "translate("
        ++ String.fromFloat trans.x
        ++ "px, "
        ++ String.fromFloat trans.y
        ++ "px) rotate("
        ++ String.fromFloat trans.rotation
        ++ "rad) scale("
        ++ String.fromFloat trans.scale
        ++ ")"


renderTargetAnimatedStyle : Maybe Transform -> List Animated -> String
renderTargetAnimatedStyle transform props =
    case props of
        [] ->
            case transform of
                Nothing ->
                    ""

                Just details ->
                    "transform: "
                        ++ transformToString details
                        ++ ";"

        (Anim _ _ name (AnimFloat val unit)) :: remaining ->
            if name == "rotate" then
                case transform of
                    Nothing ->
                        renderTargetAnimatedStyle
                            (Just
                                { scale = 1
                                , x = 0
                                , y = 0
                                , rotation = val
                                }
                            )
                            remaining

                    Just trans ->
                        renderTargetAnimatedStyle
                            (Just
                                { scale = trans.scale
                                , x = trans.x
                                , y = trans.y
                                , rotation = val
                                }
                            )
                            remaining

            else if name == "scale" then
                case transform of
                    Nothing ->
                        renderTargetAnimatedStyle
                            (Just
                                { scale = val
                                , x = 0
                                , y = 0
                                , rotation = 0
                                }
                            )
                            remaining

                    Just trans ->
                        renderTargetAnimatedStyle
                            (Just
                                { scale = val
                                , x = trans.x
                                , y = trans.y
                                , rotation = trans.rotation
                                }
                            )
                            remaining

            else
                renderTargetAnimatedStyle transform remaining
                    ++ name
                    ++ ":"
                    ++ String.fromFloat val
                    ++ unit
                    ++ " !important;"

        (Anim _ _ name (AnimTwo details)) :: remaining ->
            if name == "position" then
                case transform of
                    Nothing ->
                        renderTargetAnimatedStyle
                            (Just
                                { scale = 1
                                , x = details.one
                                , y = details.two
                                , rotation = 0
                                }
                            )
                            remaining

                    Just trans ->
                        renderTargetAnimatedStyle
                            (Just
                                { scale = trans.scale
                                , x = details.one
                                , y = details.two
                                , rotation = trans.rotation
                                }
                            )
                            remaining

            else
                renderTargetAnimatedStyle transform remaining
                    ++ name
                    ++ ":"
                    ++ String.fromFloat details.one
                    ++ details.oneUnit
                    ++ " "
                    ++ String.fromFloat details.two
                    ++ details.twoUnit
                    ++ " !important;"

        (Anim _ _ name (AnimQuad details)) :: remaining ->
            renderTargetAnimatedStyle transform remaining
                ++ name
                ++ ":"
                ++ String.fromFloat details.one
                ++ details.oneUnit
                ++ " "
                ++ String.fromFloat details.two
                ++ details.twoUnit
                ++ " "
                ++ String.fromFloat details.three
                ++ details.threeUnit
                ++ " "
                ++ String.fromFloat details.four
                ++ details.fourUnit
                ++ " !important;"

        (Anim _ _ name (AnimColor (Style.Rgb red green blue))) :: remaining ->
            let
                redStr =
                    String.fromInt red

                greenStr =
                    String.fromInt green

                blueStr =
                    String.fromInt blue
            in
            renderTargetAnimatedStyle transform remaining
                ++ name
                ++ (":rgb(" ++ redStr)
                ++ ("," ++ greenStr)
                ++ ("," ++ blueStr)
                ++ ") !important;"


renderStylesString : List TransitionDetails -> String
renderStylesString transitions =
    case transitions of
        [] ->
            ""

        top :: remaining ->
            renderStylesString remaining ++ top.prop ++ ":" ++ top.val ++ " !important;"


transitionFor : (Personality -> Approach) -> Bool -> List Animated -> String
transitionFor toApproach transformRendered animated =
    case animated of
        [] ->
            ""

        (Anim _ transition propName _) :: remaining ->
            let
                isTransform =
                    propName == "rotate" || propName == "scale" || propName == "position"
            in
            if isTransform && transformRendered then
                transitionFor toApproach transformRendered remaining

            else
                let
                    prop =
                        if isTransform then
                            "transform"

                        else
                            propName

                    approach =
                        toApproach transition

                    duration =
                        BitField.get Bits.duration approach.durDelay

                    delay =
                        BitField.get Bits.delay approach.durDelay

                    curve =
                        "cubic-bezier("
                            ++ (String.fromFloat (BitField.getPercentage Bits.bezOne approach.curve) ++ ", ")
                            ++ (String.fromFloat
                                    (BitField.getPercentage Bits.bezTwo approach.curve)
                                    ++ ", "
                               )
                            ++ (String.fromFloat
                                    (BitField.getPercentage Bits.bezThree approach.curve)
                                    ++ ", "
                               )
                            ++ (String.fromFloat
                                    (BitField.getPercentage Bits.bezFour approach.curve)
                                    ++ " "
                               )
                            ++ ")"

                    transitionStr =
                        prop ++ " " ++ String.fromInt duration ++ "ms " ++ curve ++ String.fromInt delay ++ "ms"
                in
                -- transition: <property> <duration> <timing-function> <delay>;
                case remaining of
                    [] ->
                        transitionStr

                    _ ->
                        transitionFor toApproach (isTransform || transformRendered) remaining ++ ", " ++ transitionStr


renderArrivingTransitionString : List TransitionDetails -> String
renderArrivingTransitionString transitions =
    case transitions of
        [] ->
            ""

        top :: remaining ->
            let
                transition =
                    case top.transition of
                        Transition deets ->
                            deets

                duration =
                    BitField.get Bits.duration transition.arriving.durDelay

                delay =
                    BitField.get Bits.delay transition.arriving.durDelay

                curve =
                    "cubic-bezier("
                        ++ (String.fromFloat (BitField.getPercentage Bits.bezOne transition.arriving.curve) ++ ", ")
                        ++ (String.fromFloat (BitField.getPercentage Bits.bezTwo transition.arriving.curve) ++ ", ")
                        ++ (String.fromFloat (BitField.getPercentage Bits.bezThree transition.arriving.curve) ++ ", ")
                        ++ (String.fromFloat (BitField.getPercentage Bits.bezFour transition.arriving.curve) ++ " ")
                        ++ ") "

                transitionStr =
                    top.prop ++ " " ++ String.fromInt duration ++ "ms " ++ curve ++ String.fromInt delay ++ "ms"
            in
            -- transition: <property> <duration> <timing-function> <delay>;
            case remaining of
                [] ->
                    transitionStr

                _ ->
                    renderArrivingTransitionString remaining ++ ", " ++ transitionStr


renderDepartingTransitionString : List TransitionDetails -> String
renderDepartingTransitionString transitions =
    case transitions of
        [] ->
            ""

        top :: remaining ->
            renderDepartingTransitionString remaining ++ top.prop ++ " 200ms"


transitionDetailsToClass : TransitionDetails -> String
transitionDetailsToClass details =
    transitionToClass details.transition


transitionToClass : Transition -> String
transitionToClass (Transition transition) =
    BitField.toString transition.arriving.durDelay
        ++ "-"
        ++ BitField.toString transition.arriving.curve
        ++ "-"
        ++ BitField.toString transition.departing.durDelay
        ++ "-"
        ++ BitField.toString transition.departing.curve


mapAttr : (a -> b) -> Attribute a -> Attribute b
mapAttr fn (Attribute attr) =
    Attribute
        { flag = attr.flag
        , attr =
            case attr.attr of
                Attr a ->
                    Attr
                        { node = a.node
                        , attrs = List.map (Attr.map fn) a.attrs
                        , class = a.class
                        , styles = a.styles
                        , nearby =
                            Maybe.map (\( loc, elem ) -> ( loc, map fn elem )) a.nearby
                        , transform = a.transform
                        , teleport = a.teleport
                        }
        }


type Layout
    = AsRow
    | AsWrappedRow
    | AsColumn
    | AsEl
    | AsGrid
    | AsParagraph
    | AsTextColumn
    | AsRoot


{-| -}
type Id
    = Id String String


toCssClass : Id -> String
toCssClass (Id one two) =
    one ++ "_" ++ two


toCssId : Id -> String
toCssId (Id one two) =
    one ++ "_" ++ two


noAttr : Attribute msg
noAttr =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Nothing
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


justFlag : Flag -> Attribute msg
justFlag flag =
    Attribute
        { flag = flag
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Nothing
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


nearby : Location -> Element msg -> Attribute msg
nearby loc el =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Nothing
                , styles = []
                , nearby = Just ( loc, el )
                , transform = Nothing
                , teleport = Nothing
                }
        }


teleport :
    { class : String
    , style : List ( String, String )
    , data : Encode.Value
    }
    -> Attribute msg
teleport options =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Just options.class
                , styles = options.style
                , nearby = Nothing
                , transform = Nothing
                , teleport = Just options.data
                }
        }


class : String -> Attribute msg
class cls =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Just cls
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


classWith : Flag -> String -> Attribute msg
classWith flag cls =
    Attribute
        { flag = flag
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Just cls
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


transformPiece : TransformSlot -> Float -> Attribute msg
transformPiece slot value =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Nothing
                , styles = []
                , nearby = Nothing
                , transform = Just ( slot, value )
                , teleport = Nothing
                }
        }


type alias TransformSlot =
    Int


type Attribute msg
    = Attribute
        { flag : Flag
        , attr : Attr msg
        }



-- type Attr msg
--     = NoAttribute
--     | OnPress msg
--     | OnKey (Html.Attribute msg)
--     | Attr (Html.Attribute msg)
--     | Link
-- { newTab : Bool
-- , url : String
-- , download : Maybe String
-- }
--     | WidthFill Int
--     | HeightFill Int
--     | Font
--         { family : String
--         , adjustments : Maybe (Inheritance.Encoded)
--         , variants : String
--         , smallCaps : Bool
--         , weight : String
--         , size : String
--         }
--     | FontSize Int
--     | Spacing Int Int
--     | Padding Edges
--     | TransformPiece TransformSlot Float
--     | Class String
--     | Style
--         { class : String
--         , styleName : String
--         , styleVal : String
--         }
--     | Style2
--         { oneName : String
--         , oneVal : String
--         , twoName : String
--         , twoVal : String
--         }
--     | Nearby Location (Element msg)
--     | CssTeleport
--         { class : String
--         , style : List ( String, String )
--         , data : Encode.Value
--         }


type Attr msg
    = Attr
        { node : Node
        , attrs : List (Html.Attribute msg)
        , class : Maybe String
        , styles : List ( String, String )
        , nearby : Maybe ( Location, Element msg )
        , transform : Maybe ( TransformSlot, Float )
        , teleport : Maybe Encode.Value
        }


type Node
    = NodeAsDiv
    | NodeAsLink
    | NodeAsParagraph
    | NodeAsButton
      -- Accessibility nodes
    | NodeAsH1
    | NodeAsH2
    | NodeAsH3
    | NodeAsH4
    | NodeAsH5
    | NodeAsH6
    | NodeAsNav
    | NodeAsMain
    | NodeAsAside
    | NodeAsSection
    | NodeAsArticle
    | NodeAsNumberedList
    | NodeAsBulletedList


type ResponsiveInt
    = StaticInt Int
    | ResponsiveInt String


type Trigger
    = OnHovered
    | OnPressed
    | OnFocused
    | OnIf Bool


type Animated
    = Anim String Personality String AnimValue


type AnimValue
    = AnimFloat Float String
    | AnimColor Style.Color
    | AnimTwo
        { one : Float
        , oneUnit : String
        , two : Float
        , twoUnit : String
        }
    | AnimQuad
        { one : Float
        , oneUnit : String
        , two : Float
        , twoUnit : String
        , three : Float
        , threeUnit : String
        , four : Float
        , fourUnit : String
        }


type alias Approach =
    { durDelay : BitField.Bits Bits.Transition
    , curve : BitField.Bits Bits.Bezier
    }


type alias Personality =
    { arriving : Approach
    , departing : Approach
    , wobble : Float
    }


type alias TransitionDetails =
    { phase : Phase
    , class : String
    , transition : Transition
    , prop : String
    , val : String
    }


hasFlags flags (Attribute attr) =
    List.any (Flag.equal attr.flag) flags


type Location
    = Above
    | Below
    | OnRight
    | OnLeft
    | InFront
    | Behind


type Option
    = FocusStyleOption FocusStyle
    | ResponsiveBreakpoints String
    | FontAdjustment
        { family : String
        , offset : Float
        , height : Float
        }


type Transition
    = Transition
        { arriving :
            Approach
        , departing :
            Approach
        }


type Phase
    = Hovered
    | Focused
    | Pressed


{-| -}
type alias FocusStyle =
    { borderColor : Maybe Style.Color
    , backgroundColor : Maybe Style.Color
    , shadow :
        Maybe Style.Shadow
    }


focusDefaultStyle : FocusStyle
focusDefaultStyle =
    { backgroundColor = Nothing
    , borderColor = Nothing
    , shadow =
        Just
            { x = 0
            , y = 0
            , color =
                Style.Rgb 155 203 255
            , blur = 0
            , size = 3
            }
    }


type NearbyChildren msg
    = NoNearbyChildren
    | ChildrenBehind (List (Html.Html msg))
    | ChildrenInFront (List (Html.Html msg))
    | ChildrenBehindAndInFront (List (Html.Html msg)) (List (Html.Html msg))


emptyPair : ( Int, Int )
emptyPair =
    ( 0, 0 )


emptyEdges =
    { top = 0
    , left = 0
    , bottom = 0
    , right = 0
    }


emptyDetails : Details
emptyDetails =
    { fontSize = -1
    , transform = Nothing
    , teleportData = []
    }


unwrapKeyed : Inheritance.Encoded -> ( String, Element msg ) -> ( String, Html.Html msg )
unwrapKeyed s el =
    case el of
        ( key, Element html ) ->
            ( key, html s )


wrapText s el =
    case el of
        Element html ->
            html s


text : String -> Element msg
text str =
    Element
        (\encoded ->
            if
                BitField.has Inheritance.isRow encoded
                    || BitField.has Inheritance.isColumn encoded
                    || BitField.has Inheritance.hasTextModification encoded
            then
                Html.span [ Attr.class textElementClasses ] [ Html.text str ]

            else
                Html.text str
         -- if BitField.equal encoded Bits.row || BitField.equal encoded Bits.column then
         --     Html.span [ Attr.class textElementClasses ] [ Html.text str ]
         -- else
         --     let
         --         height =
         --             encoded
         --                 |> BitField.getPercentage Bits.fontHeight
         --         offset =
         --             encoded
         --                 |> BitField.getPercentage Bits.fontOffset
         --         spacingY =
         --             encoded
         --                 |> BitField.get Bits.spacingY
         --         spacingX =
         --             encoded
         --                 |> BitField.get Bits.spacingX
         --         attrs =
         --             [ Attr.class textElementClasses
         --             ]
         --         attrsWithParentSpacing =
         --             -- if height == 1 && offset == 0 then
         --             --     Attr.style "margin"
         --             --         (String.fromInt spacingY ++ "px " ++ String.fromInt spacingX ++ "px")
         --             --         ::
         --             --         attrs
         --             -- else
         --             --     let
         --             --         -- This doesn't totally make sense to me, but it works :/
         --             --         -- I thought that the top margin should have a smaller negative margin than the bottom
         --             --         -- however it seems evenly distributing the empty space works out.
         --             --         topVal =
         --             --             offset
         --             --         bottomVal =
         --             --             (1 - height) - offset
         --             --         even =
         --             --             (topVal + bottomVal) / 2
         --             --         margin =
         --             --             "-"
         --             --                 ++ String.fromFloat (even + 0.25)
         --             --                 ++ "em "
         --             --                 ++ (String.fromInt spacingX ++ "0px ")
         --             --     in
         --             --     Attr.style "margin"
         --             --         margin
         --             --         :: Attr.style "padding" "0.25em calc((1/32) * 1em) 0.25em 0px"
         --             --         :: attrs
         --             attrs
         --     in
         --     Html.span
         --         attrsWithParentSpacing
         --         [ Html.text str ]
        )


none : Element msg
none =
    Element (\_ -> Html.text "")


type alias Rendered msg =
    { name : String
    , htmlAttrs : List (VirtualDom.Attribute msg)
    , nearby : NearbyChildren msg
    , wrapped : List Wrapped
    }


type Wrapped
    = InLink String


attrIf bool attr =
    if bool then
        attr

    else
        noAttr


attribute a =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = [ a ]
                , class = Nothing
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


attributeWith flag a =
    Attribute
        { flag = flag
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = [ a ]
                , class = Nothing
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


attrList flag list =
    Attribute
        { flag = flag
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = list
                , class = Nothing
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


onPress :
    msg
    -> Attribute msg
onPress msg =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsButton
                , attrs =
                    [ Events.onClick msg

                    --     Events.stopPropagationOn "pointerdown"
                    --     (Json.succeed ( msg, True ))
                    -- , onKeyListener "Enter"
                    --     msg
                    -- , Attr.tabindex
                    --     0
                    ]
                , class = Just Style.classes.cursorPointer
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


onKey :
    { key : String
    , msg : msg
    }
    -> Attribute msg
onKey details =
    let
        decode code =
            if code == details.key then
                Json.succeed details.msg

            else
                Json.fail "Not the enter key"

        isKey =
            Json.field "key" Json.string
                |> Json.andThen decode
    in
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsLink
                , attrs =
                    [ Events.preventDefaultOn "keyup"
                        (Json.map
                            (\fired ->
                                ( fired
                                , True
                                )
                            )
                            isKey
                        )
                    , Attr.tabindex 0
                    ]
                , class = Nothing
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


link :
    { newTab : Bool
    , url : String
    , download : Maybe String
    }
    -> Attribute msg
link details =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsLink
                , attrs =
                    [ Attr.href details.url
                    , Attr.rel "noopener noreferrer"
                    , case details.download of
                        Nothing ->
                            Attr.target
                                (if details.newTab then
                                    "_blank"

                                 else
                                    "_self"
                                )

                        Just downloadName ->
                            Attr.download downloadName
                    ]
                , class = Nothing
                , styles = []
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


style : String -> String -> Attribute msg
style name val =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Nothing
                , styles = [ ( name, val ) ]
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


style2 :
    String
    -> String
    -> String
    -> String
    -> Attribute msg
style2 oneName oneVal twoName twoVal =
    Attribute
        { flag = Flag.skip
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Nothing
                , styles = [ ( oneName, oneVal ), ( twoName, twoVal ) ]
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


styleWith : Flag -> String -> String -> Attribute msg
styleWith flag name val =
    Attribute
        { flag = flag
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Nothing
                , styles = [ ( name, val ) ]
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


styleAndClass :
    Flag
    ->
        { class : String
        , styleName : String
        , styleVal : String
        }
    -> Attribute msg
styleAndClass flag v =
    Attribute
        { flag = flag
        , attr =
            Attr
                { node = NodeAsDiv
                , attrs = []
                , class = Just v.class
                , styles = [ ( v.styleName, v.styleVal ) ]
                , nearby = Nothing
                , transform = Nothing
                , teleport = Nothing
                }
        }


type alias Edges =
    { top : Int
    , right : Int
    , bottom : Int
    , left : Int
    }


type alias Details =
    { fontSize : Int
    , transform : Maybe Transform
    , teleportData : List Json.Value
    }


spacerTop : Float -> Html.Html msg
spacerTop space =
    Html.div
        [ Attr.style "margin-top"
            ("calc(var(--vacuum-top) * (1em/var(--font-size-factor)) + "
                ++ String.fromFloat space
                ++ "px)"
            )
        ]
        []


spacerBottom : Float -> Html.Html msg
spacerBottom space =
    Html.div
        [ Attr.style "margin-top"
            ("calc(var(--vacuum-bottom) * (1em/var(--font-size-factor)) + "
                ++ String.fromFloat space
                ++ "px)"
            )
        ]
        []


renderLayout :
    { options : List Option }
    -> State
    -> List (Attribute msg)
    -> Element msg
    -> Html.Html msg
renderLayout { options } (State state) attrs content =
    let
        rendered =
            element NodeAsDiv
                AsRoot
                attrs
                [ Element
                    (\_ ->
                        Html.Keyed.node "div"
                            []
                            [ ( "options", Html.Lazy.lazy renderOptions options )
                            , ( "static", staticStyles )
                            , ( "animations", Html.Lazy.lazy styleRules state.rules )
                            , ( "boxes"
                              , Html.div [] (List.map viewBox state.boxes)
                              )
                            ]
                    )
                , content
                ]
    in
    case rendered of
        Element toFinalLayout ->
            toFinalLayout zero


staticStyles : Html.Html msg
staticStyles =
    Html.div []
        [ Html.node "style"
            []
            [ Html.text Style.rules ]
        ]


styleRules : List String -> Html.Html msg
styleRules styleStr =
    Html.div []
        [ Html.node "style"
            []
            [ Html.text (String.join "\n" styleStr) ]
        ]


viewBox ( boxId, box ) =
    Html.div
        [ Attr.style "position" "absolute"
        , Attr.style "left" (String.fromFloat box.x ++ "px")
        , Attr.style "top" (String.fromFloat box.y ++ "px")
        , Attr.style "width" (String.fromFloat box.width ++ "px")
        , Attr.style "height" (String.fromFloat box.height ++ "px")
        , Attr.style "z-index" "10"
        , Attr.style "background-color" "rgba(255,0,0,0.1)"
        , Attr.style "border-radius" "3px"
        , Attr.style "border" "3px dashed rgba(255,0,0,0.2)"
        , Attr.style "box-sizing" "border-box"
        , Attr.style "pointer-events" "none"
        ]
        [--Html.text (Debug.toString id)
        ]


element :
    Node
    -> Layout
    -> List (Attribute msg)
    -> List (Element msg)
    -> Element msg
element node layout attrs children =
    Element
        (\parentBits ->
            let
                myBaseBits =
                    Inheritance.clearSpacing parentBits
                        |> BitField.flip Inheritance.isRow (layout == AsRow)
                        |> BitField.flip Inheritance.isColumn (layout == AsColumn)

                ( analyzedBits, myBits ) =
                    analyze Flag.none BitField.init myBaseBits attrs

                htmlAttrs =
                    toAttrs parentBits myBits Flag.none [] [] attrs

                styleAttrs =
                    if BitField.has AnalyzeBits.cssVars analyzedBits then
                        let
                            transformString =
                                if BitField.has AnalyzeBits.transforms analyzedBits then
                                    "transform:" ++ toTransformString parentBits myBits Flag.none 0 1 0 0 0 attrs ++ ";"

                                else
                                    ""
                        in
                        Attr.property "style"
                            (Encode.string
                                (toStyleString parentBits myBits Flag.none transformString attrs)
                            )
                            :: htmlAttrs

                    else
                        let
                            startingProps =
                                if BitField.has AnalyzeBits.transforms analyzedBits then
                                    Attr.style "transform" (toTransformString parentBits myBits Flag.none 0 1 0 0 0 attrs)
                                        :: htmlAttrs

                                else
                                    htmlAttrs
                        in
                        toStyle parentBits myBits Flag.none startingProps (contextClasses layout) attrs

                -- classStr =
                --     toClass parentBits myBits Flag.none (contextClasses layout) attrs
                finalChildren =
                    toChildren myBits analyzedBits attrs children
            in
            if BitField.has AnalyzeBits.isLink analyzedBits then
                Html.a styleAttrs finalChildren

            else if BitField.has AnalyzeBits.isButton analyzedBits then
                Html.button styleAttrs finalChildren

            else
                case node of
                    NodeAsDiv ->
                        Html.div styleAttrs finalChildren

                    NodeAsLink ->
                        Html.a styleAttrs finalChildren

                    NodeAsParagraph ->
                        Html.p styleAttrs finalChildren

                    NodeAsButton ->
                        Html.button styleAttrs finalChildren

                    NodeAsH1 ->
                        Html.h1 styleAttrs finalChildren

                    NodeAsH2 ->
                        Html.h2 styleAttrs finalChildren

                    NodeAsH3 ->
                        Html.h3 styleAttrs finalChildren

                    NodeAsH4 ->
                        Html.h4 styleAttrs finalChildren

                    NodeAsH5 ->
                        Html.h5 styleAttrs finalChildren

                    NodeAsH6 ->
                        Html.h6 styleAttrs finalChildren

                    NodeAsNav ->
                        Html.nav styleAttrs finalChildren

                    NodeAsMain ->
                        Html.main_ styleAttrs finalChildren

                    NodeAsAside ->
                        Html.aside styleAttrs finalChildren

                    NodeAsSection ->
                        Html.section styleAttrs finalChildren

                    NodeAsArticle ->
                        Html.article styleAttrs finalChildren

                    NodeAsNumberedList ->
                        Html.ol styleAttrs finalChildren

                    NodeAsBulletedList ->
                        Html.ul styleAttrs finalChildren
        )


toTransformString :
    Inheritance.Encoded
    -> Inheritance.Encoded
    -> Flag.Field
    -> Float
    -> Float
    -> Float
    -> Float
    -> Float
    -> List (Attribute msg)
    -> String
toTransformString parentBits myBits has rotation scale x y z attrs =
    case attrs of
        [] ->
            "translate("
                ++ String.fromFloat x
                ++ "px, "
                ++ String.fromFloat y
                ++ "px, "
                ++ String.fromFloat z
                ++ "px) rotate("
                ++ String.fromFloat rotation
                ++ "rad) scale("
                ++ String.fromFloat scale
                ++ ")"

        (Attribute { flag, attr }) :: remain ->
            let
                alwaysRender =
                    case flag of
                        Flag.Flag f ->
                            f == 0

                previouslyRendered =
                    if alwaysRender then
                        False

                    else
                        Flag.present flag has
            in
            if previouslyRendered then
                toTransformString parentBits myBits has rotation scale x y z remain

            else
                case attr of
                    Attr details ->
                        case details.transform of
                            Nothing ->
                                toTransformString parentBits myBits (Flag.add flag has) rotation scale x y z remain

                            Just ( 0, newX ) ->
                                toTransformString parentBits myBits (Flag.add flag has) rotation scale newX y z remain

                            Just ( 1, newY ) ->
                                toTransformString parentBits myBits (Flag.add flag has) rotation scale x newY z remain

                            Just ( 2, newRotation ) ->
                                toTransformString parentBits myBits (Flag.add flag has) newRotation scale x y z remain

                            Just ( 3, newScale ) ->
                                toTransformString parentBits myBits (Flag.add flag has) rotation newScale x y z remain

                            _ ->
                                toTransformString parentBits myBits (Flag.add flag has) rotation scale x y z remain


toChildren :
    Inheritance.Encoded
    -> AnalyzeBits.Encoded
    -> List (Attribute msg)
    -> List (Element msg)
    -> List (Html.Html msg)
toChildren myBits analyzedBits attrs children =
    if BitField.has AnalyzeBits.nearbys analyzedBits then
        let
            behind =
                toBehindElements myBits [] attrs

            after =
                toNearbyElements myBits [] attrs
        in
        behind ++ List.map (\(Element toChild) -> toChild myBits) children ++ after

    else
        List.map (\(Element toChild) -> toChild myBits) children


elementKeyed :
    String
    -> Layout
    -> List (Attribute msg)
    -> List ( String, Element msg )
    -> Element msg
elementKeyed name layout attrs children =
    Element
        (\parentBits ->
            -- let
            --     rendered =
            --         renderAttrs
            --             parentBits
            --             (Bits.clearSpacing parentBits
            --                 |> (if layout == AsRow then
            --                         BitField.set Bits.isRow 1
            --                     else
            --                         BitField.set Bits.isRow 0
            --                    )
            --                 |> (if layout == AsParagraph then
            --                         BitField.set Bits.isParagraph 1
            --                     else
            --                         BitField.set Bits.isParagraph 0
            --                    )
            --             )
            --             layout
            --             emptyDetails
            --             (ElemKeyed children emptyKeyedNearbys)
            --             Flag.none
            --             []
            --             -- the "" below is the starting class
            --             -- though we want some defaults based on the layout
            --             (contextClasses layout)
            --             (List.reverse attrs)
            --     finalAttrs =
            --         if Flag.present Flag.hasCssVars rendered.fields then
            --             let
            --                 styleStr =
            --                     renderInlineStylesToString
            --                         parentBits
            --                         rendered.myBits
            --                         layout
            --                         rendered.details
            --                         rendered.fields
            --                         ""
            --                         (List.reverse attrs)
            --             in
            --             Attr.property "style"
            --                 (Encode.string
            --                     styleStr
            --                 )
            --                 :: rendered.attrs
            --         else
            --             rendered.attrs
            -- in
            -- case rendered.children of
            --     Keyed finalChildren ->
            --         Html.Keyed.node
            --             (if Flag.present Flag.isLink rendered.fields then
            --                 "a"
            --              else
            --                 name
            --             )
            --             finalAttrs
            --             finalChildren
            --     _ ->
            --         Html.div finalAttrs []
            Html.div [] []
        )


emptyKeyedNearbys =
    { behind = []
    , inFront = []
    }


type ElemChildren msg
    = ElemChildren
        (List (Element msg))
        { behind : List (Element msg)
        , inFront : List (Element msg)
        }
    | ElemKeyed
        (List ( String, Element msg ))
        { behind : List ( String, Element msg )
        , inFront : List ( String, Element msg )
        }


type Children msg
    = Children (List (Html.Html msg))
    | Keyed (List ( String, Html.Html msg ))


fontSizeAdjusted : Int -> Float -> Float
fontSizeAdjusted size height =
    toFloat size * (1 / height)


{-|

    1. What nodes are we rendering?
    2. Do any attributes use css variables?
    3. Are there any transforms?

-}
analyze :
    Flag.Field
    -> AnalyzeBits.Encoded
    -> Inheritance.Encoded
    -> List (Attribute msg)
    -> ( AnalyzeBits.Encoded, Inheritance.Encoded )
analyze has encoded inheritance attrs =
    case attrs of
        [] ->
            ( encoded, inheritance )

        (Attribute { flag, attr }) :: remain ->
            let
                alwaysRender =
                    case flag of
                        Flag.Flag f ->
                            f == 0

                previouslyRendered =
                    if alwaysRender then
                        False

                    else
                        Flag.present flag has
            in
            if previouslyRendered then
                analyze has encoded inheritance remain

            else
                case attr of
                    Attr details ->
                        let
                            newEncoded =
                                encoded
                                    |> BitField.flipIf AnalyzeBits.transforms (details.transform /= Nothing)
                                    |> BitField.flipIf AnalyzeBits.nearbys (details.nearby /= Nothing)
                                    |> BitField.flipIf AnalyzeBits.cssVars
                                        (Flag.equal Flag.fontGradient flag)
                                    |> BitField.flipIf AnalyzeBits.isLink
                                        (NodeAsLink == details.node)
                                    |> BitField.flipIf AnalyzeBits.isButton
                                        ((NodeAsButton == details.node)
                                            && not (BitField.has AnalyzeBits.isLink encoded)
                                        )

                            newInheritance =
                                inheritance
                                    |> BitField.flipIf Inheritance.hasTextModification
                                        (Flag.equal Flag.fontGradient flag || Flag.equal Flag.fontEllipsis flag)
                        in
                        analyze (Flag.add flag has) newEncoded newInheritance remain


toAttrs :
    Inheritance.Encoded
    -> Inheritance.Encoded
    -> Flag.Field
    -> List (VirtualDom.Attribute msg)
    -> List Json.Value
    -> List (Attribute msg)
    -> List (Html.Attribute msg)
toAttrs parentBits myBits has htmlAttrs teleported attrs =
    case attrs of
        [] ->
            case teleported of
                [] ->
                    htmlAttrs

                _ ->
                    Attr.property "data-elm-ui" (Encode.list identity teleported) :: htmlAttrs

        (Attribute { flag, attr }) :: remain ->
            let
                alwaysRender =
                    case flag of
                        Flag.Flag f ->
                            f == 0

                previouslyRendered =
                    if alwaysRender then
                        False

                    else
                        Flag.present flag has
            in
            if previouslyRendered then
                toAttrs parentBits myBits has htmlAttrs teleported remain

            else
                case attr of
                    Attr details ->
                        case details.attrs of
                            [] ->
                                toAttrs parentBits myBits has htmlAttrs teleported remain

                            _ ->
                                let
                                    newAttrs =
                                        case details.attrs of
                                            [] ->
                                                htmlAttrs

                                            [ single ] ->
                                                single :: htmlAttrs

                                            [ first, second ] ->
                                                first :: second :: htmlAttrs

                                            list ->
                                                list ++ htmlAttrs

                                    newTeleported =
                                        case details.teleport of
                                            Nothing ->
                                                teleported

                                            Just newTele ->
                                                newTele :: teleported
                                in
                                toAttrs parentBits myBits (Flag.add flag has) newAttrs newTeleported remain


toBehindElements :
    Inheritance.Encoded
    -> List (Html.Html msg)
    -> List (Attribute msg)
    -> List (Html.Html msg)
toBehindElements inheritance foundElems attrs =
    case attrs of
        [] ->
            foundElems

        (Attribute { attr }) :: remain ->
            case attr of
                Attr details ->
                    case details.nearby of
                        Just ( Behind, behindElem ) ->
                            toBehindElements inheritance (nearbyToHtml inheritance Behind behindElem :: foundElems) remain

                        _ ->
                            toBehindElements inheritance foundElems remain


toNearbyElements :
    Inheritance.Encoded
    -> List (Html.Html msg)
    -> List (Attribute msg)
    -> List (Html.Html msg)
toNearbyElements inheritance foundElems attrs =
    case attrs of
        [] ->
            foundElems

        (Attribute { attr }) :: remain ->
            case attr of
                Attr details ->
                    case details.nearby of
                        Nothing ->
                            toNearbyElements inheritance foundElems remain

                        Just ( Behind, _ ) ->
                            toNearbyElements inheritance foundElems remain

                        Just ( location, nearbyElem ) ->
                            toNearbyElements inheritance (nearbyToHtml inheritance location nearbyElem :: foundElems) remain


toClass :
    Inheritance.Encoded
    -> Inheritance.Encoded
    -> Flag.Field
    -> String
    -> List (Attribute msg)
    -> String
toClass parentBits myBits has renderedClass attrs =
    case attrs of
        [] ->
            renderedClass

        (Attribute { flag, attr }) :: remain ->
            let
                alwaysRender =
                    case flag of
                        Flag.Flag f ->
                            f == 0

                previouslyRendered =
                    if alwaysRender then
                        False

                    else
                        Flag.present flag has
            in
            if previouslyRendered then
                toClass parentBits myBits has renderedClass remain

            else
                case attr of
                    Attr details ->
                        case details.class of
                            Nothing ->
                                toClass parentBits myBits has renderedClass remain

                            Just classStr ->
                                toClass parentBits myBits (Flag.add flag has) (renderedClass ++ " " ++ classStr) remain


toStyle :
    Inheritance.Encoded
    -> Inheritance.Encoded
    -> Flag.Field
    -> List (VirtualDom.Attribute msg)
    -> String
    -> List (Attribute msg)
    -> List (Html.Attribute msg)
toStyle parentBits myBits has htmlAttrs classes attrs =
    case attrs of
        [] ->
            Attr.class classes :: htmlAttrs

        (Attribute { flag, attr }) :: remain ->
            let
                alwaysRender =
                    case flag of
                        Flag.Flag f ->
                            f == 0

                previouslyRendered =
                    if alwaysRender then
                        False

                    else
                        Flag.present flag has
            in
            if previouslyRendered then
                toStyle parentBits myBits has htmlAttrs classes remain

            else
                case attr of
                    Attr details ->
                        -- let
                        --     newClasses =
                        --         case details.class of
                        --             Nothing ->
                        --                 classes
                        --             Just classStr ->
                        --                 classes ++ " " ++ classStr
                        -- in
                        -- case details.class of
                        --     Nothing ->
                        case details.styles of
                            [] ->
                                toStyle parentBits myBits has htmlAttrs classes remain

                            [ ( name, val ) ] ->
                                toStyle parentBits myBits (Flag.add flag has) (Attr.style name val :: htmlAttrs) classes remain

                            [ ( name, val ), ( twoName, twoVal ) ] ->
                                toStyle parentBits myBits (Flag.add flag has) (Attr.style name val :: Attr.style twoName twoVal :: htmlAttrs) classes remain

                            list ->
                                toStyle parentBits myBits (Flag.add flag has) (addStyles list htmlAttrs) classes remain



-- Just classStr ->
--     case details.styles of
--         [] ->
--             toStyle parentBits myBits has htmlAttrs (classes ++ " " ++ classStr) remain
--         [ ( name, val ) ] ->
--             toStyle parentBits myBits (Flag.add flag has) (Attr.style name val :: htmlAttrs) (classes ++ " " ++ classStr) remain
--         [ ( name, val ), ( twoName, twoVal ) ] ->
-- toStyle parentBits myBits (Flag.add flag has) (Attr.style name val :: Attr.style twoName twoVal :: htmlAttrs) (classes ++ " " ++ classStr) remain
--     list ->
--         toStyle parentBits myBits (Flag.add flag has) (addStyles list htmlAttrs) (classes ++ " " ++ classStr) remain
-- case details.class of
--     Nothing ->
--         case details.styles of
--             [] ->
--                 toStyle parentBits myBits has htmlAttrs classes remain
--             [ ( name, val ) ] ->
--                 toStyle parentBits myBits (Flag.add flag has) htmlAttrs (classes ++ " " ++ name) remain
--             [ ( name, val ), ( twoName, twoVal ) ] ->
--                 toStyle parentBits myBits (Flag.add flag has) htmlAttrs (classes ++ " " ++ name ++ " " ++ twoName) remain
--             list ->
--                 toStyle parentBits myBits (Flag.add flag has) (addStyles list htmlAttrs) classes remain
--     Just classStr ->
--         case details.styles of
--             [] ->
--                 toStyle parentBits myBits has htmlAttrs (classes ++ " " ++ classStr) remain
--             [ ( name, val ) ] ->
--                 toStyle parentBits myBits (Flag.add flag has) htmlAttrs (classes ++ " " ++ classStr ++ " " ++ name) remain
--             [ ( name, val ), ( twoName, twoVal ) ] ->
--                 toStyle parentBits myBits (Flag.add flag has) htmlAttrs (classes ++ " " ++ classStr ++ " " ++ name ++ " " ++ twoName) remain
--             list ->
--                 toStyle parentBits myBits (Flag.add flag has) (addStyles list htmlAttrs) (classes ++ " " ++ classStr) remain


addStyles : List ( String, String ) -> List (Html.Attribute msg) -> List (Html.Attribute msg)
addStyles styles attrs =
    case styles of
        [] ->
            attrs

        ( name, val ) :: remain ->
            addStyles remain
                (Attr.style name val :: attrs)


toStyleString :
    Inheritance.Encoded
    -> Inheritance.Encoded
    -> Flag.Field
    -> String
    -> List (Attribute msg)
    -> String
toStyleString parentBits myBits has str attrs =
    case attrs of
        [] ->
            str

        (Attribute { flag, attr }) :: remain ->
            let
                alwaysRender =
                    case flag of
                        Flag.Flag f ->
                            f == 0

                previouslyRendered =
                    if alwaysRender then
                        False

                    else
                        Flag.present flag has
            in
            if previouslyRendered then
                toStyleString parentBits myBits has str remain

            else
                case attr of
                    Attr details ->
                        case details.styles of
                            [] ->
                                toStyleString parentBits myBits has str remain

                            [ ( name, val ) ] ->
                                toStyleString parentBits myBits (Flag.add flag has) (name ++ ":" ++ val ++ ";" ++ str) remain

                            [ ( name, val ), ( twoName, twoVal ) ] ->
                                toStyleString parentBits myBits (Flag.add flag has) (name ++ ":" ++ val ++ ";" ++ twoName ++ ":" ++ twoVal ++ ";" ++ str) remain

                            list ->
                                toStyleString parentBits myBits (Flag.add flag has) (addStylesToString list str) remain


addStylesToString : List ( String, String ) -> String -> String
addStylesToString styles attrs =
    case styles of
        [] ->
            attrs

        ( name, val ) :: remain ->
            addStylesToString remain
                (name ++ ":" ++ val ++ ";" ++ attrs)



-- {-| We track a number of things in the function and it can be difficult to remember exactly why.
-- A lot of these questions essentially fall to, "do we do the work or do we count on the browser to do it."
-- So, let's try to give an overview of all the systems:
--   - In order to render Font.gradient, (possibly) TextColumn spacing, and Responsive.value/fluid, we need to maintain css variables
--     This means detecting if we need to render a css variable, and at the end, rerender styles as a `Property` instead of `style`.
-- -}
-- renderAttrs :
--     Inheritance.Encoded
--     -> Inheritance.Encoded
--     -> Layout
--     -> Details
--     -> ElemChildren msg
--     -> Flag.Field
--     -> List (VirtualDom.Attribute msg)
--     -> String
--     -> List (Attribute msg)
--     ->
--         { fields : Flag.Field
--         , myBits : Inheritance.Encoded
--         , details : Details
--         , attrs : List (Html.Attribute msg)
--         , children : Children msg
--         }
-- renderAttrs parentBits myBits layout details children has htmlAttrs classes attrs =
--     case attrs of
--         [] ->
--             let
--                 attrsWithParentSpacing =
--                     if Bits.hasSpacing parentBits && BitField.has Bits.isParagraph parentBits then
--                         Attr.style "margin"
--                             ((parentBits
--                                 |> BitField.get Bits.spacingY
--                                 |> String.fromInt
--                              )
--                                 ++ "px "
--                                 ++ (parentBits
--                                         |> BitField.get Bits.spacingX
--                                         |> String.fromInt
--                                    )
--                                 ++ "px"
--                             )
--                             :: htmlAttrs
--                     else
--                         htmlAttrs
--                 attrsWithTransform =
--                     case details.transform of
--                         Nothing ->
--                             attrsWithParentSpacing
--                         Just trans ->
--                             Attr.style "transform"
--                                 (transformToString trans)
--                                 :: attrsWithParentSpacing
--                 adjustmentNotSet =
--                     not (Flag.present Flag.fontAdjustment has)
--                 -- {-
--                 --    no fontsize or adjustment -> skip
--                 --    if fontsize is set, not adjustment:
--                 --        -> set fontsize px
--                 --    adjsutment, not fontsize
--                 --        -> set font size (em
--                 --    if both are set
--                 --        -> fontsize px
--                 -- -}
--                 -- attrsWithFontSize =
--                 --     if details.fontSize == -1 && adjustmentNotSet then
--                 --         -- no fontsize or adjustment set
--                 --         attrsWithTransform
--                 --     else if adjustmentNotSet then
--                 --         -- font size is set, not adjustment
--                 --         -- set font size, adjust via inherited value
--                 --         let
--                 --             height =
--                 --                 parentBits
--                 --                     |> BitField.getPercentage Bits.fontHeight
--                 --         in
--                 --         Attr.style "font-size"
--                 --             (String.fromFloat
--                 --                 (toFloat details.fontSize * (1 / height))
--                 --                 ++ "px"
--                 --             )
--                 --             :: attrsWithTransform
--                 --     else if details.fontSize /= -1 then
--                 --         -- a font size is set as well as an adjustment
--                 --         -- set font size from details
--                 --         let
--                 --             fontHeight =
--                 --                 myBits
--                 --                     |> BitField.getPercentage Bits.fontHeight
--                 --         in
--                 --         Attr.style "font-size"
--                 --             (String.fromFloat
--                 --                 (toFloat details.fontSize * (1 / fontHeight))
--                 --                 ++ "px"
--                 --             )
--                 --             :: attrsWithTransform
--                 --     else
--                 --         -- a font size is NOT set, but we have an adjustment
--                 --         -- operate on `em`
--                 --         let
--                 --             fontHeight =
--                 --                 myBits
--                 --                     |> BitField.getPercentage Bits.fontHeight
--                 --         in
--                 --         Attr.style "font-size"
--                 --             (String.fromFloat
--                 --                 (1 / fontHeight)
--                 --                 ++ "em"
--                 --             )
--                 --             :: attrsWithTransform
--                 attrsWithAnimations =
--                     case details.teleportData of
--                         [] ->
--                             attrsWithTransform
--                         teleportData ->
--                             Attr.property "data-elm-ui" (Encode.list identity teleportData)
--                                 :: attrsWithTransform
--                 attrsWithWidthFill =
--                     if Flag.present Flag.width has then
--                         -- we know we've set the width to fill
--                         attrsWithAnimations
--                         -- else if
--                         --     not
--                         --         (Flag.present Flag.borderWidth has
--                         --             || Flag.present Flag.background has
--                         --             || Flag.present Flag.event has
--                         --         )
--                         --         && not (BitField.has Bits.isRow parentBits)
--                         -- then
--                         --     Attr.class Style.classes.widthFill
--                         --         :: attrsWithAnimations
--                     else
--                         -- we are not widthFill, we set it to widthContent
--                         Attr.class Style.classes.widthContent
--                             :: attrsWithAnimations
--                 finalAttrs =
--                     if Flag.present Flag.height has then
--                         -- we know we've set the width to fill
--                         Attr.class classes
--                             :: attrsWithWidthFill
--                         -- else if
--                         --     not
--                         --         (Flag.present Flag.borderWidth has
--                         --             || Flag.present Flag.background has
--                         --             || Flag.present Flag.event has
--                         --         )
--                         --         && BitField.has Bits.isRow parentBits
--                         -- then
--                         --     Attr.class (classes ++ " " ++ Style.classes.heightFill)
--                         --         :: attrsWithWidthFill
--                     else
--                         Attr.class (classes ++ " " ++ Style.classes.heightContent)
--                             :: attrsWithWidthFill
--                 {- RENDER NEARBY CHILDREN -}
--                 renderedChildren =
--                     case children of
--                         ElemChildren elems nearbyRecord ->
--                             Children <|
--                                 (List.map (unwrap myBits) nearbyRecord.behind
--                                     ++ List.map (unwrap myBits) elems
--                                     ++ List.map (unwrap myBits) nearbyRecord.inFront
--                                 )
--                         ElemKeyed keyedElems nearbyRecord ->
--                             Keyed <|
--                                 List.map
--                                     (unwrapKeyed myBits)
--                                     nearbyRecord.behind
--                                     ++ List.map (unwrapKeyed myBits) keyedElems
--                                     ++ List.map
--                                         (unwrapKeyed myBits)
--                                         nearbyRecord.inFront
--                 spacingY =
--                     BitField.get Bits.spacingY myBits
--                 finalChildren =
--                     -- case renderedChildren of
--                     --     Keyed keyedChilds ->
--                     --         case layout of
--                     --             AsParagraph ->
--                     --                 Keyed <|
--                     --                     if Flag.present Flag.id has then
--                     --                         -- ( "ui-movable", Html.Keyed.node "div" (Attr.class "ui-movable" :: finalAttrs) keyedChilds )
--                     --                             -- :: ( "top-spacer", spacerTop (toFloat spacingY / -2) )
--                     --                             -- ::
--                     --                             keyedChilds
--                     --                         -- ++ [ ( "bottom-spacer", spacerBottom (toFloat spacingY / -2) ) ]
--                     --                     else
--                     --                         -- ( "top-spacer", spacerTop (toFloat spacingY / -2) )
--                     --                         -- ::
--                     --                         keyedChilds
--                     --             -- ++ [ ( "bottom-spacer", spacerBottom (toFloat spacingY / -2) ) ]
--                     --             _ ->
--                     --                 if Flag.present Flag.id has then
--                     --                     -- (( "ui-movable", Html.Keyed.node "div" (Attr.class "ui-movable" :: finalAttrs) keyedChilds )
--                     --                         -- ::
--                     --                          keyedChilds
--                     --                     -- )
--                     --                         |> Keyed
--                     --                 else
--                     --                     renderedChildren
--                     --     Children childs ->
--                     --         case layout of
--                     --             AsParagraph ->
--                     --                 Children <|
--                     --                     if Flag.present Flag.id has then
--                     --                         Html.div (Attr.class "ui-movable" :: finalAttrs) childs
--                     --                             -- :: spacerTop (toFloat spacingY / -2)
--                     --                             :: childs
--                     --                         -- ++ [ spacerBottom (toFloat spacingY / -2) ]
--                     --                     else
--                     --                         -- spacerTop (toFloat spacingY / -2)
--                     --                         -- ::
--                     --                         childs
--                     --             -- ++ [ spacerBottom (toFloat spacingY / -2) ]
--                     --             _ ->
--                     --                 if Flag.present Flag.id has then
--                     --                     (Html.div (Attr.class "ui-movable" :: finalAttrs) childs
--                     --                         :: childs
--                     --                     )
--                     --                         |> Children
--                     --                 else
--                     --                     renderedChildren
--                     renderedChildren
--             in
--             { fields = has
--             , myBits = myBits
--             , attrs = finalAttrs
--             , children = finalChildren
--             , details = details
--             }
--         (Attribute { flag, attr }) :: remain ->
-- let
--     alwaysRender =
--         case flag of
--             Flag.Flag f ->
--                 f == 0
--     previouslyRendered =
--         if alwaysRender then
--             False
--         else
--             Flag.present flag has
-- in
-- if previouslyRendered then
--     renderAttrs parentBits myBits layout details children has htmlAttrs classes remain
-- else
--                 case attr of
--                     NoAttribute ->
--                         renderAttrs parentBits myBits layout details children has htmlAttrs classes remain
--                     FontSize size ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             (Attr.style "font-size"
--                                 (String.fromFloat
--                                     (fontSizeAdjusted size
--                                         (parentBits
--                                             |> BitField.getPercentage Bits.fontHeight
--                                         )
--                                     )
--                                     ++ "px"
--                                 )
--                                 :: htmlAttrs
--                             )
--                             classes
--                             remain
--                     Font font ->
--                         let
--                             withSmallcaps =
--                                 if font.smallCaps then
--                                     Attr.style "font-variant-caps" "small-caps"
--                                         :: htmlAttrs
--                                 else
--                                     htmlAttrs
--                             withFeatures =
--                                 if font.variants == "" then
--                                     withSmallcaps
--                                 else
--                                     Attr.style "font-feature-settings" font.variants
--                                         :: withSmallcaps
--                         in
--                         renderAttrs parentBits
--                             (case font.adjustments of
--                                 Nothing ->
--                                     myBits
--                                 Just adj ->
--                                     myBits
--                                         |> BitField.copy Bits.fontHeight adj
--                                         |> BitField.copy Bits.fontOffset adj
--                             )
--                             layout
--                             { fontSize = details.fontSize
--                             , transform = details.transform
--                             , teleportData = details.teleportData
--                             }
--                             children
--                             (case font.adjustments of
--                                 Nothing ->
--                                     has
--                                 Just _ ->
--                                     Flag.add Flag.fontAdjustment has
--                             )
--                             (Attr.style "font-family" font.family
--                                 :: Attr.style "font-size" font.size
--                                 :: Attr.style "font-weight" font.weight
--                                 :: withFeatures
--                             )
--                             classes
--                             remain
--                     TransformPiece slot val ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             { details | transform = Just (upsertTransform slot val details.transform) }
--                             children
--                             (Flag.add flag has)
--                             htmlAttrs
--                             classes
--                             remain
--                     Attr htmlAttr ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             (htmlAttr :: htmlAttrs)
--                             classes
--                             remain
--                     OnPress msg ->
--                         -- Make focusable
--                         -- Attach keyboard handler
--                         -- Attach click handler
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             (Events.stopPropagationOn "pointerdown"
--                                 (Json.succeed ( msg, True ))
--                                 :: onKey "Enter" msg
--                                 :: Attr.tabindex 0
--                                 :: htmlAttrs
--                             )
--                             (Style.classes.cursorPointer
--                                 ++ " "
--                                 ++ classes
--                             )
--                             remain
--                     OnKey handler ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             (handler
--                                 :: Attr.tabindex 0
--                                 :: htmlAttrs
--                             )
--                             classes
--                             remain
--                     Link link ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
-- (Attr.href link.url
--     :: Attr.rel "noopener noreferrer"
--     :: (case link.download of
--             Nothing ->
--                 Attr.target
--                     (if link.newTab then
--                         "_blank"
--                      else
--                         "_self"
--                     )
--             Just downloadName ->
--                 Attr.download downloadName
--        )
--                                 :: htmlAttrs
--                             )
--                             classes
--                             remain
--                     Style2 styleDetails ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             (Attr.style styleDetails.oneName styleDetails.oneVal
--                                 :: Attr.style styleDetails.twoName styleDetails.twoVal
--                                 :: htmlAttrs
--                             )
--                             classes
--                             remain
--                     Style styleDetails ->
--                         let
--                             isVar =
--                                 String.startsWith "--" styleDetails.styleName
--                         in
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (if isVar then
--                                 has
--                                     |> Flag.add flag
--                                     |> Flag.add Flag.hasCssVars
--                              else
--                                 Flag.add flag has
--                             )
--                             (if isVar then
--                                 htmlAttrs
--                              else
--                                 Attr.style styleDetails.styleName styleDetails.styleVal :: htmlAttrs
--                             )
--                             (case styleDetails.class of
--                                 "" ->
--                                     classes
--                                 newClass ->
--                                     newClass ++ " " ++ classes
--                             )
--                             remain
--                     Class str ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             htmlAttrs
--                             (str ++ " " ++ classes)
--                             remain
--                     Nearby location elem ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             (addNearbyElement location elem children)
--                             has
--                             htmlAttrs
--                             classes
--                             remain
--                     Spacing x y ->
--                         renderAttrs parentBits
--                             (if layout == AsTextColumn || layout == AsParagraph then
--                                 myBits
--                                     |> BitField.set Bits.spacingX x
--                                     |> BitField.set Bits.spacingY y
--                              else
--                                 myBits
--                             )
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             (Attr.style "gap"
--                                 (String.fromInt y
--                                     ++ "px "
--                                     ++ String.fromInt x
--                                     ++ "px"
--                                 )
--                                 :: htmlAttrs
--                             )
--                             (Style.classes.spacing ++ " " ++ classes)
--                             remain
--                     Padding padding ->
--                         -- This is tracked because we're doing something weird with Input rendering.
--                         -- Myabe it's not necessary if we get smarter about how the Text input is rendered?
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             (if padding.top == padding.right && padding.top == padding.left && padding.top == padding.bottom then
--                                 Attr.style "padding"
--                                     (String.fromInt padding.top ++ "px")
--                                     :: htmlAttrs
--                              else
--                                 Attr.style "padding"
--                                     ((String.fromInt padding.top ++ "px ")
--                                         ++ (String.fromInt padding.right ++ "px ")
--                                         ++ (String.fromInt padding.bottom ++ "px ")
--                                         ++ (String.fromInt padding.left ++ "px")
--                                     )
--                                     :: htmlAttrs
--                             )
--                             classes
--                             remain
--                     HeightFill i ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             -- we're in a column
--                             (if i > 1 && not (BitField.has Bits.isRow parentBits) then
--                                 Attr.style "flex-grow" (String.fromInt (i * 100000))
--                                     :: htmlAttrs
--                              else
--                                 htmlAttrs
--                             )
--                             (if i <= 0 then
--                                 classes
--                              else
--                                 Style.classes.heightFill
--                                     ++ " "
--                                     ++ classes
--                             )
--                             remain
--                     WidthFill i ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             details
--                             children
--                             (Flag.add flag has)
--                             (if i > 1 && BitField.has Bits.isRow parentBits then
--                                 Attr.style "flex-grow" (String.fromInt (i * 100000))
--                                     :: htmlAttrs
--                              else
--                                 htmlAttrs
--                             )
--                             (if i <= 0 then
--                                 classes
--                              else
--                                 Style.classes.widthFill
--                                     ++ " "
--                                     ++ classes
--                             )
--                             remain
--                     CssTeleport teleport ->
--                         renderAttrs parentBits
--                             myBits
--                             layout
--                             { fontSize = details.fontSize
--                             , transform = details.transform
--                             , teleportData = teleport.data :: details.teleportData
--                             }
--                             children
--                             (Flag.add flag has)
--                             (htmlAttrs
--                                 |> addStyles teleport.style
--                             )
--                             (teleport.class ++ " " ++ classes)
--                             remain
-- {-| In order to make css variables work, we need to gather all styles into a `Attribute.property "style"`
-- However, that method is slower than calling `Html.Attributes.style` directly,
-- because it requires the browser to parse the string instead of setting styles directly via style.setProperty or whatever.
-- This does mean we only want to use css variables sparingly.
-- -}
-- renderInlineStylesToString :
--     Inheritance.Encoded
--     -> Inheritance.Encoded
--     -> Layout
--     -> Details
--     -> Flag.Field
--     -> String
--     -> List (Attribute msg)
--     -> String
-- renderInlineStylesToString parentBits myBits layout details has vars attrs =
--     case attrs of
--         [] ->
--             let
--                 varsWithParentSpacing =
--                     -- if Bits.hasSpacing parentBits && (layout == AsParagraph || layout == AsTextColumn) then
--                     --     "margin: "
--                     --         ++ ((parentBits
--                     --                 |> BitField.get Bits.spacingY
--                     --                 |> String.fromInt
--                     --             )
--                     --                 ++ "px "
--                     --                 ++ (parentBits
--                     --                         |> BitField.get Bits.spacingX
--                     --                         |> String.fromInt
--                     --                    )
--                     --                 ++ "px;"
--                     --            )
--                     --         ++ vars
--                     -- else
--                     vars
--                 varsWithTransform =
--                     case details.transform of
--                         Nothing ->
--                             varsWithParentSpacing
--                         Just trans ->
--                             "transform: "
--                                 ++ transformToString trans
--                                 ++ ";"
--                                 ++ varsWithParentSpacing
--                 adjustmentNotSet =
--                     not (Flag.present Flag.fontAdjustment has)
--                 {-
--                    no fontsize or adjustment -> skip
--                    if fontsize is set, not adjustment:
--                        -> set fontsize px
--                    adjsutment, not fontsize
--                        -> set font size (em
--                    if both are set
--                        -> fontsize px
--                 -}
--                 varsWithFontSize =
--                     if details.fontSize == -1 && adjustmentNotSet then
--                         -- no fontsize or adjustment set
--                         varsWithTransform
--                     else if adjustmentNotSet then
--                         -- font size is set, not adjustment
--                         -- set font size, adjust via inherited value
--                         let
--                             height =
--                                 parentBits
--                                     |> BitField.getPercentage Bits.fontHeight
--                         in
--                         "font-size: "
--                             ++ (String.fromFloat
--                                     (toFloat details.fontSize * (1 / height))
--                                     ++ "px;"
--                                )
--                             ++ varsWithTransform
--                     else if details.fontSize /= -1 then
--                         -- a font size is set as well as an adjustment
--                         -- set font size from details
--                         let
--                             fontHeight =
--                                 myBits
--                                     |> BitField.getPercentage Bits.fontHeight
--                         in
--                         "font-size: "
--                             ++ (String.fromFloat
--                                     (toFloat details.fontSize * (1 / fontHeight))
--                                     ++ "px;"
--                                )
--                             ++ varsWithTransform
--                     else
--                         -- a font size is NOT set, but we have an adjustment
--                         -- operate on `em`
--                         let
--                             fontHeight =
--                                 myBits
--                                     |> BitField.getPercentage Bits.fontHeight
--                         in
--                         "font-size: "
--                             ++ (String.fromFloat
--                                     (1 / fontHeight)
--                                     ++ "em;"
--                                )
--                             ++ varsWithTransform
--             in
--             varsWithFontSize
--         (Attribute { flag, attr }) :: remain ->
--             let
--                 alwaysRender =
--                     case flag of
--                         Flag.Flag f ->
--                             f == 0
--                 previouslyRendered =
--                     if alwaysRender then
--                         False
--                     else
--                         Flag.present flag has
--             in
--             if previouslyRendered then
--                 renderInlineStylesToString parentBits myBits layout details has vars remain
--             else
--                 case attr of
--                     FontSize size ->
--                         renderInlineStylesToString parentBits
--                             myBits
--                             layout
--                             details
--                             (Flag.add flag has)
--                             (vars
--                                 ++ ("font-size: "
--                                         ++ String.fromFloat
--                                             (fontSizeAdjusted size
--                                                 (parentBits
--                                                     |> BitField.getPercentage Bits.fontHeight
--                                                 )
--                                             )
--                                         ++ "px;"
--                                    )
--                             )
--                             remain
--                     Font font ->
--                         let
--                             withSmallcaps =
--                                 if font.smallCaps then
--                                     vars ++ "font-variant-caps: small-caps;"
--                                 else
--                                     vars
--                             withFeatures =
--                                 if font.variants == "" then
--                                     vars
--                                 else
--                                     vars ++ "font-feature-settings: " ++ font.variants ++ ";"
--                         in
--                         renderInlineStylesToString parentBits
--                             myBits
--                             layout
--                             details
--                             (Flag.add flag has)
--                             (withFeatures
--                                 ++ ("font-family:" ++ font.family ++ ";")
--                                 ++ ("font-size:" ++ font.size ++ ";")
--                                 ++ ("font-weight:" ++ font.weight ++ ";")
--                             )
--                             remain
--                     Style styleDetails ->
--                         renderInlineStylesToString parentBits
--                             myBits
--                             layout
--                             details
--                             (Flag.add flag has)
--                             (vars ++ styleDetails.styleName ++ ":" ++ styleDetails.styleVal ++ ";")
--                             remain
--                     Spacing x y ->
--                         renderInlineStylesToString parentBits
--                             myBits
--                             layout
--                             details
--                             (Flag.add flag has)
--                             (if layout == AsParagraph then
--                                 vars
--                                     ++ "line-height:"
--                                     ++ ("calc(1em + " ++ String.fromInt y ++ "px;")
--                              else
--                                 vars
--                                     ++ "gap:"
--                                     ++ (String.fromInt y
--                                             ++ "px "
--                                             ++ String.fromInt x
--                                             ++ "px;"
--                                        )
--                             )
--                             remain
--                     Padding padding ->
--                         renderInlineStylesToString parentBits
--                             myBits
--                             layout
--                             details
--                             (Flag.add flag has)
--                             (if padding.top == padding.right && padding.top == padding.left && padding.top == padding.bottom then
--                                 vars
--                                     ++ "padding: "
--                                     ++ (String.fromInt padding.top ++ "px;")
--                              else
--                                 vars
--                                     ++ "padding: "
--                                     ++ ((String.fromInt padding.top ++ "px ")
--                                             ++ (String.fromInt padding.right ++ "px ")
--                                             ++ (String.fromInt padding.bottom ++ "px ")
--                                             ++ (String.fromInt padding.left ++ "px;")
--                                        )
--                             )
--                             remain
--                     HeightFill i ->
--                         renderInlineStylesToString parentBits
--                             myBits
--                             layout
--                             details
--                             (Flag.add flag has)
--                             (if i > 1 && not (BitField.has Bits.isRow parentBits) then
--                                 vars
--                                     ++ "flex-grow: "
--                                     ++ String.fromInt (i * 100000)
--                                     ++ ";"
--                              else
--                                 vars
--                             )
--                             remain
--                     WidthFill i ->
--                         renderInlineStylesToString parentBits
--                             myBits
--                             layout
--                             details
--                             (Flag.add flag has)
--                             (if i > 1 && BitField.has Bits.isRow parentBits then
--                                 vars
--                                     ++ "flex-grow: "
--                                     ++ String.fromInt (i * 100000)
--                                     ++ ";"
--                              else
--                                 vars
--                             )
--                             remain
--                     CssTeleport teleport ->
--                         renderInlineStylesToString parentBits
--                             myBits
--                             layout
--                             details
--                             (Flag.add flag has)
--                             (vars
--                                 |> addStylesToString teleport.style
--                             )
--                             remain
--                     _ ->
--                         renderInlineStylesToString parentBits
--                             myBits
--                             layout
--                             details
--                             (Flag.add flag has)
--                             vars
--                             remain


triggerName : Trigger -> String
triggerName trigger =
    case trigger of
        OnHovered ->
            "on-hovered"

        OnPressed ->
            "on-pressed"

        OnFocused ->
            "on-focused"

        OnIf bool ->
            -- Note, could trigger this via attribute index
            ""


{-| -}
onKeyListener : String -> msg -> Html.Attribute msg
onKeyListener desiredCode msg =
    let
        decode code =
            if code == desiredCode then
                Json.succeed msg

            else
                Json.fail "Not the enter key"

        isKey =
            Json.field "key" Json.string
                |> Json.andThen decode
    in
    Events.preventDefaultOn "keyup"
        (Json.map
            (\fired ->
                ( fired, True )
            )
            isKey
        )


upsertTransform : Int -> Float -> Maybe Transform -> Transform
upsertTransform slot val maybeTransform =
    let
        t =
            Maybe.withDefault emptyTransform maybeTransform
    in
    { scale =
        if slot - 3 == 0 then
            val

        else
            t.scale
    , x =
        if slot - 0 == 0 then
            val

        else
            t.x
    , y =
        if slot - 1 == 0 then
            val

        else
            t.y
    , rotation =
        if slot - 2 == 0 then
            val

        else
            t.rotation
    }


nearbyToHtml : Inheritance.Encoded -> Location -> Element msg -> Html.Html msg
nearbyToHtml inheritance location (Element elem) =
    Html.div
        [ Attr.class <|
            case location of
                Above ->
                    Style.classes.nearby
                        ++ Style.classes.single
                        ++ Style.classes.above

                Below ->
                    Style.classes.nearby
                        ++ Style.classes.single
                        ++ Style.classes.below

                OnRight ->
                    Style.classes.nearby
                        ++ Style.classes.single
                        ++ Style.classes.onRight

                OnLeft ->
                    Style.classes.nearby
                        ++ Style.classes.single
                        ++ Style.classes.onLeft

                InFront ->
                    Style.classes.nearby
                        ++ Style.classes.single
                        ++ Style.classes.inFront

                Behind ->
                    Style.classes.nearby
                        ++ Style.classes.single
                        ++ Style.classes.behind
        ]
        [ elem inheritance
        ]


zero =
    BitField.init


textElementClasses : String
textElementClasses =
    Style.classes.any
        ++ " "
        ++ Style.classes.text
        ++ " "
        ++ Style.classes.widthContent
        ++ " "
        ++ Style.classes.heightContent


rootClass =
    Style.classes.root
        ++ " "
        ++ Style.classes.any
        ++ " "
        ++ Style.classes.single


rowClass =
    Style.classes.any
        ++ " "
        ++ Style.classes.row
        ++ " "
        ++ Style.classes.nowrap
        ++ " "
        ++ Style.classes.contentLeft
        ++ " "
        ++ Style.classes.contentCenterY


wrappedRowClass =
    Style.classes.any ++ " " ++ Style.classes.row ++ " " ++ Style.classes.wrapped


columnClass =
    Style.classes.any
        ++ " "
        ++ Style.classes.column
        ++ " "
        ++ Style.classes.contentTop
        ++ " "
        ++ Style.classes.contentLeft


singleClass =
    Style.classes.any ++ " " ++ Style.classes.single


gridClass =
    Style.classes.any ++ " " ++ Style.classes.grid


paragraphClass =
    Style.classes.any ++ " " ++ Style.classes.paragraph


textColumnClass =
    Style.classes.any ++ " " ++ Style.classes.page


contextClasses context =
    case context of
        AsRow ->
            rowClass

        AsWrappedRow ->
            wrappedRowClass

        AsColumn ->
            columnClass

        AsRoot ->
            rootClass

        AsEl ->
            singleClass

        AsGrid ->
            gridClass

        AsParagraph ->
            paragraphClass

        AsTextColumn ->
            textColumnClass



{- DECODERS -}


decodeBoundingBox2 =
    Json.field "currentTarget"
        (Json.map4
            Box
            (Json.field "clientLeft" Json.float)
            (Json.field "clientTop" Json.float)
            (Json.field "clientWidth" Json.float)
            (Json.field "clientHeight" Json.float)
        )


decodeBoundingBox : Json.Decoder Box
decodeBoundingBox =
    Json.field "target"
        (Json.map3
            (\w h ( top, left ) ->
                -- Debug.log "final"
                { width = w
                , height = h
                , x = left
                , y = top
                }
            )
            (Json.field "offsetWidth" Json.float)
            (Json.field "offsetHeight" Json.float)
            (decodeElementPosition True 0 0)
        )


type alias ElementBox =
    { clientLeft : Float
    , clientTop : Float
    , offsetLeft : Float
    , offsetTop : Float
    }


decodeInitialElementPosition =
    Json.map4 ElementBox
        (Json.field "clientLeft" Json.float)
        (Json.field "clientTop" Json.float)
        (Json.field "offsetLeft" Json.float)
        (Json.field "offsetTop" Json.float)


{-| -}
decodeElementPosition : Bool -> Float -> Float -> Json.Decoder ( Float, Float )
decodeElementPosition ignoreBorders top left =
    Json.oneOf
        [ Json.field "offsetParent" (Json.nullable (Json.succeed ()))
            |> Json.andThen
                (\maybeNull ->
                    case maybeNull of
                        Nothing ->
                            -- there is no offset parent
                            Json.map4
                                (\clientLeft clientTop offsetLeft offsetTop ->
                                    let
                                        newTop =
                                            if ignoreBorders then
                                                top + offsetTop

                                            else
                                                top + (offsetTop + clientTop)

                                        newLeft =
                                            if ignoreBorders then
                                                left + offsetLeft

                                            else
                                                left + (offsetLeft + clientLeft)
                                    in
                                    ( newTop, newLeft )
                                )
                                (Json.field "clientLeft" Json.float)
                                (Json.field "clientTop" Json.float)
                                (Json.field "offsetLeft" Json.float)
                                (Json.field "offsetTop" Json.float)

                        Just () ->
                            -- there is an offset parent
                            Json.map4
                                (\clientLeft clientTop offsetLeft offsetTop ->
                                    let
                                        newTop =
                                            if ignoreBorders then
                                                top + offsetTop

                                            else
                                                top + (offsetTop + clientTop)

                                        newLeft =
                                            if ignoreBorders then
                                                left + offsetLeft

                                            else
                                                left + (offsetLeft + clientLeft)
                                    in
                                    ( newTop, newLeft )
                                )
                                (Json.field "clientLeft" Json.float)
                                (Json.field "clientTop" Json.float)
                                (Json.field "offsetLeft" Json.float)
                                (Json.field "offsetTop" Json.float)
                                |> Json.andThen
                                    (\( newTop, newLeft ) ->
                                        Json.field "offsetParent"
                                            (Json.lazy
                                                (\_ ->
                                                    decodeElementPosition
                                                        False
                                                        newTop
                                                        newLeft
                                                )
                                            )
                                    )
                )
        , Json.succeed ( top, left )
        ]


type alias Overflow =
    { moreOnLeft : Bool
    , moreOnRight : Bool
    , moreAbove : Bool
    , moreBelow : Bool
    }


defaultOverflow : Overflow
defaultOverflow =
    { moreOnLeft = False
    , moreOnRight = False
    , moreAbove = False
    , moreBelow = False
    }


decodeScrollPosition : Json.Decoder Overflow
decodeScrollPosition =
    Json.field "target"
        (Json.map6
            (\scrollLeft scrollTop clientWidth clientHeight scrollWidth scrollHeight ->
                let
                    onLeftEdge =
                        scrollLeft == 0

                    onRightEdge =
                        abs ((clientWidth + scrollLeft) - scrollWidth) == 0
                in
                { moreOnLeft = not onLeftEdge
                , moreOnRight = not onRightEdge
                , moreAbove = scrollTop /= 0
                , moreBelow = abs ((clientHeight + scrollTop) - scrollHeight) /= 0
                }
            )
            (Json.field "scrollLeft" Json.int)
            (Json.field "scrollTop" Json.int)
            (Json.field "clientWidth" Json.int)
            (Json.field "clientHeight" Json.int)
            (Json.field "scrollWidth" Json.int)
            (Json.field "scrollHeight" Json.int)
        )



{- Responsive: Breakpoints -}


type Breakpoints label
    = Responsive
        { transition : Maybe Transition
        , default : label
        , breaks : List ( Int, label )
        , total : Int
        }


{-| -}
type Value
    = Between Int Int
    | Exactly Int


mapResonsive : (Int -> Int) -> Value -> Value
mapResonsive fn resp =
    case resp of
        Between low high ->
            Between (fn low) (fn high)

        Exactly exact ->
            Exactly (fn exact)


responsiveCssValue : Breakpoints label -> (label -> Value) -> String
responsiveCssValue resp toValue =
    calc <|
        foldBreakpoints
            (\i lab str ->
                case str of
                    "" ->
                        calc <| renderResponsiveValue i (toValue lab)

                    _ ->
                        str ++ " + " ++ calc (renderResponsiveValue i (toValue lab))
            )
            ""
            resp


{-| Things to remember when using `calc`

<https://developer.mozilla.org/en-US/docs/Web/CSS/calc()>

1.  Multiplication needs one of the arguments to be a <number>, meaning a literal, with no units!

2.  Division needs the _denominator_ to be a <number>, again literal with no units.

-}
renderResponsiveValue : Int -> Value -> String
renderResponsiveValue i v =
    ("var(" ++ breakpointString i ++ ") * ")
        ++ (case v of
                Exactly val ->
                    String.fromInt val ++ "px"

                Between bottom top ->
                    let
                        diff =
                            top - bottom
                    in
                    calc
                        (calc
                            ("var("
                                ++ breakpointString i
                                ++ "-progress) * "
                                ++ String.fromInt diff
                            )
                            ++ " + "
                            ++ String.fromInt bottom
                            ++ "px"
                        )
           )


breakpointString : Int -> String
breakpointString i =
    "--ui-bp-" ++ String.fromInt i


calc : String -> String
calc str =
    "calc(" ++ str ++ ")"


foldBreakpoints :
    (Int -> label -> result -> result)
    -> result
    -> Breakpoints label
    -> result
foldBreakpoints fn initial (Responsive resp) =
    foldBreakpointsHelper fn (fn 0 resp.default initial) 1 resp.breaks


foldBreakpointsHelper fn cursor i breaks =
    case breaks of
        [] ->
            cursor

        ( _, label ) :: remain ->
            foldBreakpointsHelper fn
                (fn i label cursor)
                (i + 1)
                remain


type alias ResponsiveTransition =
    { duration : Int
    }



{- Rendering -}


toMediaQuery : Breakpoints label -> String
toMediaQuery (Responsive details) =
    case details.breaks of
        [] ->
            ""

        ( lowerBound, _ ) :: remain ->
            ":root {"
                ++ toRoot details.breaks
                    1
                    (renderResponsiveCssVars 0 0 lowerBound)
                ++ " }"
                ++ toBoundedMediaQuery details.breaks
                    1
                    (maxWidthMediaQuery 0 lowerBound)


renderRoot : Int -> String
renderRoot breakpointCounts =
    ":root {" ++ renderRootItem breakpointCounts "" ++ "}"


renderRootItem : Int -> String -> String
renderRootItem count rendered =
    if count <= 0 then
        rendered

    else
        renderRootItem (count - 1)
            (rendered ++ "--ui-bp-" ++ String.fromInt (count - 1) ++ ": 0;")


renderResponsiveCssVars : Int -> Int -> Int -> String
renderResponsiveCssVars i lower upper =
    ("--ui-bp-" ++ String.fromInt i ++ ": 0;")
        ++ ("--ui-bp-" ++ String.fromInt i ++ "-lower: " ++ String.fromInt lower ++ "px;")
        ++ ("--ui-bp-" ++ String.fromInt i ++ "-upper: " ++ String.fromInt upper ++ "px;")
        ++ ("--ui-bp-"
                ++ String.fromInt i
                ++ "-progress: calc(calc(100vw - "
                ++ String.fromInt lower
                ++ "px) / "
                ++ String.fromInt (upper - lower)
                ++ ");"
           )


toRoot : List ( Int, label ) -> Int -> String -> String
toRoot breaks i rendered =
    case breaks of
        [] ->
            rendered

        [ ( upper, _ ) ] ->
            rendered ++ renderResponsiveCssVars i upper (upper + 1000)

        ( lower, _ ) :: ((( upper, _ ) :: _) as tail) ->
            toRoot tail
                (i + 1)
                (rendered ++ renderResponsiveCssVars i lower upper)


toBoundedMediaQuery : List ( Int, label ) -> Int -> String -> String
toBoundedMediaQuery breaks i rendered =
    case breaks of
        [] ->
            rendered

        [ ( upper, _ ) ] ->
            rendered ++ minWidthMediaQuery i upper

        ( lower, _ ) :: ((( upper, _ ) :: _) as tail) ->
            toBoundedMediaQuery tail
                (i + 1)
                (rendered ++ renderBoundedMediaQuery upper lower i)


minWidthMediaQuery : Int -> Int -> String
minWidthMediaQuery i lowerBound =
    "@media" ++ minWidth lowerBound ++ " { " ++ renderMediaProps i ++ " }"


maxWidthMediaQuery : Int -> Int -> String
maxWidthMediaQuery i upperBound =
    "@media " ++ maxWidth upperBound ++ " { " ++ renderMediaProps i ++ " }"


renderBoundedMediaQuery : Int -> Int -> Int -> String
renderBoundedMediaQuery upper lower i =
    "@media " ++ minWidth lower ++ " and " ++ maxWidth upper ++ " { " ++ renderMediaProps i ++ " }"


maxWidth : Int -> String
maxWidth int =
    "(max-width:" ++ String.fromInt int ++ "px)"


minWidth : Int -> String
minWidth int =
    "(min-width:" ++ String.fromInt (int + 1) ++ "px)"


renderMediaProps : Int -> String
renderMediaProps i =
    (":root {--ui-bp-" ++ String.fromInt i ++ ": 1;}")
        ++ (".ui-bp-" ++ String.fromInt i ++ "-hidden {display:none !important;}")
        ++ (".ui-bp-" ++ String.fromInt i ++ "-as-col {flex-direction: column;}")


{-| -}
renderOptions : List Option -> Html.Html msg
renderOptions opts =
    Html.node "style"
        []
        [ Html.text (renderOptionItem { breakpoints = False, focus = False } "" opts) ]


renderOptionItem alreadyRendered renderedStr opts =
    case opts of
        [] ->
            renderedStr

        (FocusStyleOption focus) :: remain ->
            if alreadyRendered.focus then
                renderOptionItem alreadyRendered
                    renderedStr
                    remain

            else
                renderOptionItem { alreadyRendered | focus = True }
                    (renderedStr ++ renderFocusStyle focus)
                    remain

        (ResponsiveBreakpoints mediaQueryStr) :: remain ->
            if alreadyRendered.breakpoints then
                renderOptionItem alreadyRendered
                    renderedStr
                    remain

            else
                renderOptionItem { alreadyRendered | breakpoints = True }
                    (renderedStr ++ mediaQueryStr)
                    remain

        (FontAdjustment adjustment) :: remain ->
            renderOptionItem alreadyRendered
                (renderedStr ++ renderFontAdjustment adjustment)
                remain


renderFontAdjustment :
    { family : String
    , offset : Float
    , height : Float
    }
    -> String
renderFontAdjustment adjustment =
    let
        fontid =
            adjustment.family

        sizeAdjustmentRule =
            ("." ++ fontid)
                ++ curlyBrackets
                    [ "font-size:" ++ String.fromFloat adjustment.height ++ "%;"
                    ]
    in
    sizeAdjustmentRule
        ++ (List.map
                (\i ->
                    let
                        -- offset would be 5 if the line-height is 1.05
                        offsetInt =
                            i * 5

                        body =
                            curlyBrackets
                                [ "margin-top:" ++ Generated.lineHeightAdjustment i ++ ";"
                                , "margin-bottom:" ++ Generated.lineHeightAdjustment i ++ ";"
                                ]
                    in
                    (("." ++ fontid ++ " .lh-" ++ String.fromInt offsetInt ++ " .s.p ") ++ body)
                        ++ (("." ++ fontid ++ " .lh-" ++ String.fromInt offsetInt ++ " .s.t ") ++ body)
                )
                (List.range 1 20)
                |> String.join ""
           )


curlyBrackets : List String -> String
curlyBrackets lines =
    "{" ++ String.join "" lines ++ "}"


maybeString fn maybeStr =
    case maybeStr of
        Nothing ->
            ""

        Just str ->
            fn str


andAdd one two =
    two ++ one


dot str =
    "." ++ str


renderFocusStyle :
    FocusStyle
    -> String
renderFocusStyle focus =
    let
        focusProps =
            "outline: none;"
                |> andAdd (maybeString (\color -> "border-color: " ++ Style.color color ++ ";") focus.borderColor)
                |> andAdd
                    (maybeString (\color -> "background-color: " ++ Style.color color ++ ";") focus.backgroundColor)
                |> andAdd
                    (maybeString
                        (\shadow ->
                            "box-shadow: "
                                ++ (Style.singleShadow shadow
                                    -- { color = shadow.color
                                    -- , offset =
                                    --     shadow.offset
                                    --         |> Tuple.mapFirst toFloat
                                    --         |> Tuple.mapSecond toFloat
                                    -- , inset = False
                                    -- , blur =
                                    --     toFloat shadow.blur
                                    -- , size =
                                    --     toFloat shadow.size
                                    -- }
                                   )
                                ++ ";"
                        )
                        focus.shadow
                    )
    in
    String.append
        (String.append
            (dot Style.classes.focusedWithin ++ ":focus-within")
            focusProps
        )
        (String.append
            (dot Style.classes.any ++ ":focus .focusable, " ++ dot Style.classes.any ++ ".focusable:focus")
            focusProps
        )
